pub const std_options: std.Options = .{
    .logFn = rmio.log.logFn,
};

const mtu = 1200;

const loopback: net.IpAddress = .{ .ip4 = .loopback(0) };
const default_destination = net.IpAddress.parseLiteral("127.0.0.1:15810") catch unreachable;

const destination_envvar = "REMIELLE_GAMESV_ADDRESS";

const CommandTag = enum {
    @"kick-player",
};

pub fn main(init: Init) void {
    const io = init.io;

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err|
        fatal("failed to collect command line arguments: {t}", .{err});

    const command: cli.Command = .parse(args[1..]);

    const destination = if (init.environ_map.get(destination_envvar)) |literal|
        net.IpAddress.parseLiteral(literal) catch
            fatal("'" ++ destination_envvar ++ "' contains an invalid address", .{})
    else
        default_destination;

    const socket = loopback.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch |err|
        fatal("bind: {t}", .{err});

    defer socket.close(io);

    var recv_buffer: [mtu]u8 align(@alignOf(u64)) = undefined;

    var random_impl: std.Random.IoSource = .{ .io = io };
    const random = random_impl.interface();

    const userdata = random.int(u32);

    switch (command) {
        .@"kick-player" => |kick_player| {
            const kick_message: rmnet.Operation.Message(rmnet.Operation.PlayerKick) = .init(userdata, .{
                .uid = kick_player.uid,
                .reason = kick_player.reason,
            });

            socket.send(io, &destination, @ptrCast(&kick_message)) catch |err|
                fatal("send: {t}", .{err});

            const ack = receive(rmnet.Event.Ack, io, &socket, &recv_buffer);
            _ = ack;
        },
        .@"mod-avatar-meta" => |mod_avatar_meta| {
            const value: u64 = switch (mod_avatar_meta.field) {
                _ => unreachable,
                .skill_level => skill_level: {
                    const skill: rmnet.Operation.ModAvatarMeta.Skill = .{
                        .skill = mod_avatar_meta.value,
                        .level = mod_avatar_meta.value_extra,
                    };

                    break :skill_level @bitCast(skill);
                },
                inline else => mod_avatar_meta.value,
            };

            const mod_message: rmnet.Operation.Message(rmnet.Operation.ModAvatarMeta) = .init(userdata, .{
                .player_uid = mod_avatar_meta.uid,
                .avatar_id = mod_avatar_meta.id,
                .field = mod_avatar_meta.field,
                .value = value,
            });

            socket.send(io, &destination, @ptrCast(&mod_message)) catch |err|
                fatal("send: {t}", .{err});

            const ack = receive(rmnet.Event.Ack, io, &socket, &recv_buffer);
            _ = ack;
        },
    }
}

fn receive(
    comptime ExpectedEvent: type,
    io: Io,
    socket: *const net.Socket,
    buf: *align(@alignOf(u64)) [mtu]u8,
) *const ExpectedEvent {
    const udp_message = socket.receive(io, buf) catch |err|
        fatal("receive failed: {t}", .{err});

    const data = buf[0..udp_message.data.len];

    if (data.len < @sizeOf(rmnet.ServerHeader))
        fatal("invalid packet received from the server", .{});

    const header: *rmnet.ServerHeader = @ptrCast(data[0..@sizeOf(rmnet.ServerHeader)]);

    if (header.protocol_version != rmnet.Version.current)
        fatal("server protocol version did not match: {d}", .{header.protocol_version});

    switch (header.event_tag) {
        ExpectedEvent.tag => {
            if (header.event_version != ExpectedEvent.version)
                fatal("server {t} event version doesn't match: {d}", .{ header.event_tag, header.event_version });

            const ExpectedMessage = rmnet.Event.Message(ExpectedEvent);

            if (data.len != @sizeOf(ExpectedMessage))
                fatal(
                    "received malformed message from server (expected size: {d}, received: {d})",
                    .{ @sizeOf(ExpectedMessage), data.len },
                );

            const message: *ExpectedMessage = @ptrCast(data);

            return &message.event;
        },
        .nak => {
            if (header.event_version != rmnet.Event.Nak.version)
                fatal("server {t} event version doesn't match: {d}", .{ header.event_tag, header.event_version });

            const NakMessage = rmnet.Event.Message(rmnet.Event.Nak);

            if (data.len != @sizeOf(NakMessage))
                fatal("received negative acknowledgement from server", .{});

            const nak_message: *NakMessage = @ptrCast(data);

            switch (nak_message.event.reason) {
                _ => fatal("received negative acknowledgement from server", .{}),
                else => |reason| fatal("error: {t} ({d})", .{ reason, nak_message.event.extra }),
            }
        },
        _ => |unknown| fatal("received unknown event, tag: {d}", .{@intFromEnum(unknown)}),
        // else => |unexpected| fatal("received unexpected event ({t})", .{unexpected}),
    }
}

const fatal = std.process.fatal;

const Io = std.Io;
const Init = std.process.Init;

const net = std.Io.net;

const cli = @import("cli.zig");

const rmio = @import("rmio");
const rmnet = @import("rmnet");

const builtin = @import("builtin");
const std = @import("std");
