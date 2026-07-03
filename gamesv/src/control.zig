pub const mtu: usize = 1200;

pub fn process(
    io: Io,
    current_time: Io.Timestamp,
    sockets: *const [SocketKind.count]net.Socket.Handle,
    server: *Server,
    from: *const net.IpAddress,
    data: []align(@alignOf(u64)) u8,
) !void {
    if (data.len < @sizeOf(rmnet.ClientHeader))
        return error.InvalidPacket;

    const game_socket: net.Socket = .{ .handle = sockets[SocketKind.game.toIndex()], .address = undefined };
    const ctl_socket: net.Socket = .{ .handle = sockets[SocketKind.ctl.toIndex()], .address = undefined };

    const header: *rmnet.ClientHeader = @ptrCast(data[0..@sizeOf(rmnet.ClientHeader)]);
    if (header.protocol_version != rmnet.Version.current)
        return send(rmnet.Event.Nak, io, ctl_socket, from, header.userdata, .{
            .reason = .protocol_version_mismatch,
            .extra = @intFromEnum(rmnet.Version.current),
        });

    switch (header.operation_tag) {
        .nop => {
            if (header.operation_version != rmnet.Operation.Nop.version)
                return send(rmnet.Event.Nak, io, ctl_socket, from, header.userdata, .{
                    .reason = .operation_version_mismatch,
                    .extra = rmnet.Operation.Nop.version,
                });

            try send(rmnet.Event.Ack, io, ctl_socket, from, header.userdata, .{});
        },

        .player_kick => {
            if (header.operation_version != rmnet.Operation.PlayerKick.version)
                return send(rmnet.Event.Nak, io, ctl_socket, from, header.userdata, .{
                    .reason = .operation_version_mismatch,
                    .extra = rmnet.Operation.PlayerKick.version,
                });

            const ExpectedMessage = rmnet.Operation.Message(rmnet.Operation.PlayerKick);

            if (data.len != @sizeOf(ExpectedMessage))
                return error.InvalidPacket;

            try send(rmnet.Event.Ack, io, ctl_socket, from, header.userdata, .{});

            const message: *ExpectedMessage = @ptrCast(data);

            const index: u32 = @intCast(server.uid_map.getIndex(message.operation.uid) orelse return);

            const reason: rmpb.main.PlayerKickReason = std.enums.fromInt(
                rmpb.main.PlayerKickReason,
                message.operation.reason,
            ) orelse @enumFromInt(0);

            app.notifyPlayerKick(io, game_socket, server, current_time, index, reason) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => {},
            };

            app.savePlayer(
                io,
                &server.resettable_arena,
                server.persistent,
                &server.properties,
                server.uid_map.keys()[index],
                index,
            );

            server.release(server.conv_map.keys()[index]);
        },

        _ => return send(rmnet.Event.Nak, io, ctl_socket, from, header.userdata, .{
            .reason = .unknown_operation_tag,
            .extra = 0,
        }),
    }
}

fn send(
    comptime Event: type,
    io: Io,
    socket: net.Socket,
    destination: *const net.IpAddress,
    userdata: u32,
    event: Event,
) !void {
    const message: rmnet.Event.Message(Event) = .init(userdata, event);
    try socket.send(io, destination, @ptrCast(&message));
}

const Io = std.Io;
const SocketKind = app.SocketKind;

const net = std.Io.net;

const app = @import("app.zig");
const Server = @import("Server.zig");

const rmnet = @import("rmnet");
const rmpb = @import("rmpb");
const std = @import("std");
