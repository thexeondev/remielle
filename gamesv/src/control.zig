pub const mtu: usize = 1200;

pub fn process(
    io: Io,
    sockets: *const [SocketKind.count]net.Socket.Handle,
    server: *Server,
    from: *const net.IpAddress,
    data: []align(@alignOf(u64)) u8,
) !void {
    _ = server;

    if (data.len < @sizeOf(rmnet.ClientHeader))
        return error.InvalidPacket;

    const ctl_socket = sockets[SocketKind.ctl.toIndex()];

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

        _ => return send(rmnet.Event.Nak, io, ctl_socket, from, header.userdata, .{
            .reason = .unknown_operation_tag,
            .extra = 0,
        }),
    }
}

fn send(
    comptime Event: type,
    io: Io,
    socket_handle: net.Socket.Handle,
    destination: *const net.IpAddress,
    userdata: u32,
    event: Event,
) !void {
    const message: rmnet.Event.Message(Event) = .init(userdata, event);

    const socket: net.Socket = .{ .handle = socket_handle, .address = undefined };
    try socket.send(io, destination, @ptrCast(&message));
}

const Io = std.Io;
const SocketKind = app.SocketKind;

const net = std.Io.net;

const app = @import("app.zig");
const Server = @import("Server.zig");

const rmnet = @import("rmnet");
const std = @import("std");
