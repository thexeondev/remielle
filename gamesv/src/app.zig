const remielle = @import("remielle");
const rsa = remielle.rsa;

const log = std.log.scoped(.@"remielle-gamesv");

const mtu = kcp.mtu;

pub fn bind(
    io: Io,
    gpa: Allocator,
    csprng: Random,
    assets: *const Assets,
    addresses: *const [Server.Socket.count]net.IpAddress,
    concurrent_session_limit: Io.Limit,
) Io.Cancelable!void {
    var persistent = Persistent.init(io, gpa, .cwd()) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| fatal("failed to initialize Persistent: {t}", .{e}),
    };

    defer persistent.deinit(gpa);

    var receive_buffers: [Server.Socket.count][mtu]u8 align(@alignOf(u64)) = undefined;
    var sockets_buffer: MultiSocket.Buffer(Server.Socket.count) = undefined;
    var sockets: MultiSocket = undefined;

    sockets.init(sockets_buffer.toSockets(), &.{ &receive_buffers[0], &receive_buffers[1] });
    defer sockets.deinit(io);

    for (addresses, std.enums.values(Server.Socket)) |address, socket| {
        const index = sockets.bind(io, address) catch |err| switch (err) {
            error.AddressInUse => fatal(
                "the address {f} is already in use; another instance of this server might be already running",
                .{address},
            ),
            else => |e| fatal("bind: {t}", .{e}),
        };

        std.debug.assert(index == socket.toIndex());

        log.info("waiting for {t} clients at udp://{f}", .{ socket, address });
    }

    var server: Server = .init(
        gpa,
        csprng,
        &sockets,
        assets,
        &persistent,
        concurrent_session_limit,
    );

    defer server.deinit();

    recv_loop: while (sockets.receive(io)) |completion| {
        const current_time: Io.Timestamp = .now(io, .real);

        switch (Server.Socket.fromIndex(completion.index)) {
            .game => {
                const message = completion.result catch |err| switch (err) {
                    error.MessageOversize => continue,
                    else => |e| {
                        log.err("UDP packet receive failed: {t}", .{e});
                        continue;
                    },
                };

                onGameMessageReceived(
                    io,
                    gpa,
                    csprng,
                    &server,
                    sockets.get(completion.index),
                    current_time,
                    &message,
                ) catch |err| switch (err) {
                    error.Canceled => break :recv_loop,
                    else => {},
                };
            },
            .control => {
                const message = completion.result catch |err| switch (err) {
                    error.MessageOversize => continue,
                    else => |e| {
                        log.err("ctl receive failed: {t}", .{e});
                        continue;
                    },
                };

                const data = receive_buffers[completion.index][0..message.data.len];

                control.process(io, current_time, &server, &message.from, data) catch |err| switch (err) {
                    error.Canceled => break :recv_loop,
                    else => {},
                };

                server.drainOutgoingQueue(io, current_time) catch |err| switch (err) {
                    error.Canceled => break :recv_loop,
                };
            },
        }
    } else |err| switch (err) {
        error.Canceled => {}, // shutdown
        error.Timeout => unreachable,
        error.ConcurrencyUnavailable => fatal("couldn't start receiving: concurrency is unavailable", .{}),
    }

    log.info("shutting down...", .{});

    const current_time: Io.Timestamp = .now(io, .real);

    var session_index: u32 = 0;
    while (session_index < server.conv_map.count()) : (session_index += 1)
        server.kick(io, current_time, session_index, .PlayerKickReason_ServerClose);

    persistent.saveCalendar(io) catch |err|
        log.err("failed to save calendar: {t}", .{err});
}

fn onGameMessageReceived(
    io: Io,
    gpa: Allocator,
    csprng: Random,
    server: *Server,
    socket: net.Socket,
    current_time: Io.Timestamp,
    message: *const net.IncomingMessage,
) !void {
    if (message.data.len == kcp.Control.size) {
        var out_buf: ?[kcp.Control.size]u8 = null;
        const status = server.receiveControlPacket(
            &message.from,
            .{ .buffer = message.data[0..kcp.Control.size] },
            &out_buf,
        );

        switch (status) {
            .nothing => {},
            .disconnect => |conv_id| disconnect: {
                const index: u32 = @intCast(server.conv_map.getIndex(conv_id) orelse
                    break :disconnect);

                log.debug("player from {f} disconnected", .{message.from});

                server.savePlayer(io, index);
                server.release(index);
            },
        }

        if (out_buf) |*send_buf|
            try socket.send(io, &message.from, send_buf);

        return;
    } else if (message.data.len < kcp.Header.size) return;

    const status = server.receiveKcpPacket(
        current_time,
        &message.from,
        message.data,
    ) catch |recv_err| switch (recv_err) {
        error.InvalidToken => {
            // This may happen if server has been restarted, but the game
            // had an active session.
            const kcp_header = kcp.Header.decode(message.data[0..kcp.Header.size]) catch
                unreachable;

            var ctl: [kcp.Control.size]u8 = undefined;

            kcp.Control.encode(&ctl, .disconnect, kcp_header.conv_id, kcp_header.token, 404);
            try socket.send(io, &message.from, &ctl);
            return;
        },
        error.MalformedPacket, error.FillFailed => return,
    };

    switch (status) {
        .success => {},
        .unauthenticated => |input| {
            var request_string_buffer: [1024]u8 = undefined;

            const request = messaging.expectFirstPacket(
                &request_string_buffer,
                message.data[kcp.Header.size..][0..input.header.len],
            ) catch |err| switch (err) {
                error.SizeMismatch,
                error.InvalidMagic,
                error.UnexpectedCmdId,
                error.MalformedPayload,
                => return,
            };

            const server_rand_key = csprng.int(u64);
            const rand_key = messaging.Xorpad.Key.derive(
                server_rand_key,
                request.client_rand_key,
            ) catch |err| switch (err) {
                error.RandKeyDecryptFail => return,
            };

            const account_uid = Persistent.AccountUid.fromString(request.account_uid) orelse
                return;

            const get_or_create = server.persistent.getOrCreatePlayerUid(
                io,
                account_uid,
                gpa,
            ) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.OutOfMemory, error.WriteFileFailed => |e| {
                    log.err(
                        "failed to authenticate client from {f}: {t}",
                        .{ message.from, e },
                    );
                    return;
                },
            };

            var encryption_buffer: rsa.EncryptAndSignBuffer = undefined;
            rsa.encryptAndSign(&encryption_buffer, @ptrCast(&server_rand_key));

            const response: rmpb.main.PlayerGetTokenScRsp = .{
                .uid = get_or_create.player_uid,
                .server_rand_key = &encryption_buffer.ciphertext,
                .sign = &encryption_buffer.sign,
            };

            if (server.uid_map.getIndex(get_or_create.player_uid)) |index|
                server.kick(io, current_time, @intCast(index), .PlayerKickReason_ServerClose);

            const player_index = server.onAuthSucceeded(
                &message.from,
                message.data,
                input.header.conv_id,
                input.token,
                current_time,
                rand_key,
                response,
            ) catch |err| switch (err) {
                error.MessageOversize,
                error.OutOfMemory,
                error.SessionLimitExceeded,
                error.InvalidFirstPacket,
                error.MappingFailed,
                => return,
            };

            if (get_or_create.created) {
                const old_cancel_protection = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(old_cancel_protection);

                logic.Properties.setDefaultsAt(
                    &server.properties,
                    @enumFromInt(player_index),
                );

                server.savePlayer(io, player_index);
            } else {
                try server.loadPlayerProperties(io, get_or_create.player_uid, player_index);
            }
        },
    }

    try server.drainOutgoingQueue(io, current_time);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

const Io = std.Io;
const Random = std.Random;
const Allocator = std.mem.Allocator;
const MultiSocket = rmio.MultiSocket;

const heap = std.heap;
const net = std.Io.net;

const kcp = @import("kcp.zig");
const logic = @import("logic.zig");
const Assets = @import("Assets.zig");
const Server = @import("Server.zig");
const control = @import("control.zig");
const messaging = @import("messaging.zig");
const Persistent = @import("Persistent.zig");

const rmpb = @import("rmpb");
const rmio = @import("rmio");
const std = @import("std");
