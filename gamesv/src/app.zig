const log = std.log.scoped(.@"remielle-gamesv");

const mtu = kcp.mtu;

pub const SocketKind = enum(usize) {
    game = 0,
    ctl = 1,

    pub const count = 2;

    pub fn toIndex(sk: SocketKind) usize {
        return @intFromEnum(sk);
    }

    pub fn fromIndex(index: usize) SocketKind {
        return @enumFromInt(index);
    }
};

pub fn bind(
    io: Io,
    gpa: Allocator,
    csprng: Random,
    assets: *const Assets,
    addresses: *const [SocketKind.count]net.IpAddress,
    concurrent_session_limit: Io.Limit,
) Io.Cancelable!void {
    var persistent = Persistent.init(io, gpa, .cwd()) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| fatal("failed to initialize Persistent: {t}", .{e}),
    };

    defer persistent.deinit(gpa);

    var receive_buffers: [SocketKind.count][mtu]u8 align(@alignOf(u64)) = undefined;
    var sockets_buffer: MultiSocket.Buffer(SocketKind.count) = undefined;
    var sockets: MultiSocket = undefined;

    sockets.init(sockets_buffer.toSockets(), &.{ &receive_buffers[0], &receive_buffers[1] });
    defer sockets.deinit(io);

    for (addresses, std.enums.values(SocketKind)) |address, kind| {
        const index = sockets.bind(io, address) catch |err| switch (err) {
            error.AddressInUse => fatal(
                "the address {f} is already in use; another instance of this server might be already running",
                .{address},
            ),
            else => |e| fatal("bind: {t}", .{e}),
        };

        std.debug.assert(index == @intFromEnum(kind));

        log.info("waiting for {t} clients at udp://{f}", .{ kind, address });
    }

    var server: Server = .init(
        gpa,
        csprng,
        assets,
        &persistent,
        concurrent_session_limit,
    );

    defer server.deinit();

    recv_loop: while (sockets.receive(io)) |completion| {
        const current_time: Io.Timestamp = .now(io, .real);

        switch (SocketKind.fromIndex(completion.socket_index)) {
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
                    sockets.get(completion.socket_index),
                    current_time,
                    &message,
                ) catch |err| switch (err) {
                    error.Canceled => break :recv_loop,
                    else => {},
                };
            },
            .ctl => {
                const message = completion.result catch |err| switch (err) {
                    error.MessageOversize => continue,
                    else => |e| {
                        log.err("ctl receive failed: {t}", .{e});
                        continue;
                    },
                };

                const data = receive_buffers[completion.socket_index][0..message.data.len];

                control.process(io, current_time, &sockets, &server, &message.from, data) catch |err| switch (err) {
                    error.Canceled => break :recv_loop,
                    else => {},
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
    const game_udp_socket = sockets.get(SocketKind.game.toIndex());

    // Save all online players and, if possible, kick them out gracefully
    var session_index: u32 = 0;
    while (session_index < server.conv_map.count()) : (session_index += 1) {
        savePlayer(
            io,
            &server.resettable_arena,
            &persistent,
            &server.properties,
            server.uid_map.keys()[session_index],
            session_index,
        );

        if (rmpb.features.isAvailable(.player_kick)) {
            notifyPlayerKick(
                io,
                game_udp_socket,
                &server,
                current_time,
                session_index,
                .PlayerKickReason_ServerClose,
            ) catch {};
        }
    }
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

                savePlayer(
                    io,
                    &server.resettable_arena,
                    server.persistent,
                    &server.properties,
                    server.uid_map.keys()[index],
                    index,
                );

                server.release(conv_id);
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

            var response_string_buffer: [messaging.auth.string_buffer_size]u8 = undefined;

            const player_token = messaging.auth.playerGetToken(
                gpa,
                csprng,
                server.persistent,
                &request,
                &response_string_buffer,
            ) catch |err| switch (err) {
                error.OutOfMemory,
                error.InvalidUidString,
                error.RandKeyDecryptFail,
                => |e| {
                    log.err(
                        "failed to authenticate client from {f}: {t}",
                        .{ message.from, e },
                    );
                    return;
                },
            };

            const player_index = server.onAuthSucceeded(
                &message.from,
                message.data,
                input.header.conv_id,
                input.token,
                current_time,
                player_token.key,
                player_token.response,
            ) catch |err| switch (err) {
                error.MessageOversize,
                error.OutOfMemory,
                error.SessionLimitExceeded,
                error.InvalidFirstPacket,
                error.MappingFailed,
                => return,
            };

            if (player_token.is_first_login) {
                const old_cancel_protection = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(old_cancel_protection);

                server.persistent.saveAccountUidMap(io) catch |err| switch (err) {
                    error.Canceled => unreachable, // blocked
                    else => |e| fatal("failed to save account uid map: {t}", .{e}),
                };

                logic.Properties.setDefaultsAt(
                    &server.properties,
                    current_time,
                    @enumFromInt(player_index),
                );

                savePlayer(
                    io,
                    &server.resettable_arena,
                    server.persistent,
                    &server.properties,
                    player_token.uid,
                    player_index,
                );
            } else {
                loadPlayer(
                    io,
                    &server.resettable_arena,
                    server.persistent,
                    &server.properties,
                    player_token.uid,
                    player_index,
                ) catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    else => |e| {
                        log.err(
                            "failed to load player with uid {d}: {t}",
                            .{ player_token.uid, e },
                        );

                        // Reset defaults for now.
                        logic.Properties.setDefaultsAt(
                            &server.properties,
                            current_time,
                            @enumFromInt(player_index),
                        );
                    },
                };
            }
        },
    }

    while (server.multi_conversation.nextUndrained()) |index| drainOutgoingPackets(
        io,
        socket,
        current_time,
        &server.multi_conversation,
        index,
        &message.from,
    ) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {},
    };
}

pub fn savePlayer(
    io: Io,
    resettable_arena: *heap.ArenaAllocator,
    persistent: *Persistent,
    properties: *logic.Properties.List,
    uid: u32,
    index: u32,
) void {
    defer _ = resettable_arena.reset(.retain_capacity);

    const player_save = logic.Properties.toPlayerSave(
        properties,
        resettable_arena.allocator(),
        @enumFromInt(index),
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            // TODO: get rid of protobuf for saves to avoid this error.
            log.err("ran out of memory while constructing save for UID {d}", .{uid});
            return;
        },
    };

    const old_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_cancel_protection);

    persistent.savePlayer(io, uid, player_save) catch |err| switch (err) {
        error.Canceled => unreachable, // blocked
        else => |e| log.err("failed to save player with UID {d}: {t}", .{ uid, e }),
    };
}

fn loadPlayer(
    io: Io,
    resettable_arena: *heap.ArenaAllocator,
    persistent: *Persistent,
    properties: *logic.Properties.List,
    uid: u32,
    index: u32,
) !void {
    defer _ = resettable_arena.reset(.retain_capacity);

    const player_save = try persistent.loadPlayer(
        io,
        resettable_arena.allocator(),
        uid,
    );

    try logic.Properties.fromPlayerSave(
        properties,
        @enumFromInt(index),
        &player_save,
    );
}

/// Sends `PlayerKickScNotify` followed by disconnection control packet.
pub fn notifyPlayerKick(
    io: Io,
    udp_socket: net.Socket,
    server: *Server,
    current_time: Io.Timestamp,
    index: u32,
    reason: rmpb.main.PlayerKickReason,
) !void {
    const notify: rmpb.main.PlayerKickScNotify = .{ .reason = reason };

    try messaging.send(
        &server.multi_conversation,
        &server.clients,
        index,
        .notify,
        notify,
    );

    try drainOutgoingPackets(
        io,
        udp_socket,
        current_time,
        &server.multi_conversation,
        index,
        server.clients.getPtr(.addr, index),
    );

    var ctl: [kcp.Control.size]u8 = undefined;
    const identifier = server.multi_conversation.identifierAt(index);

    kcp.Control.encode(
        &ctl,
        .disconnect,
        identifier.id,
        identifier.token.downgrade(),
        404,
    );

    try udp_socket.send(io, server.clients.getPtr(.addr, index), &ctl);
}

fn drainOutgoingPackets(
    io: Io,
    udp_socket: net.Socket,
    current_time: Io.Timestamp,
    multi_conversation: *kcp.MultiConversation,
    index: u32,
    destination: *const net.IpAddress,
) !void {
    multi_conversation.updateAt(index, current_time);

    var output_buf: [kcp.mtu]u8 = undefined;
    var it: kcp.MultiConversation.DrainIterator = .init;

    while (!it.isAtEnd()) {
        const n_send = multi_conversation.drainAt(index, &it, &output_buf);
        if (n_send == 0) continue;

        try udp_socket.send(io, destination, output_buf[0..n_send]);
    }
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
