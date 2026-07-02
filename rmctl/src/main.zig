pub const std_options: std.Options = .{
    .logFn = rmio.log.logFn,
};

const loopback: net.IpAddress = .{ .ip4 = .loopback(0) };
const default_destination = net.IpAddress.parseLiteral("127.0.0.1:15810") catch unreachable;

const destination_envvar = "REMIELLE_GAMESV_ADDRESS";

pub fn main(init: Init) void {
    const io = init.io;

    const destination = if (init.environ_map.get(destination_envvar)) |literal|
        net.IpAddress.parseLiteral(literal) catch
            fatal("'" ++ destination_envvar ++ "' contains an invalid address", .{})
    else
        default_destination;

    const socket = loopback.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch |err|
        fatal("bind: {t}", .{err});

    defer socket.close(io);

    var random_impl: std.Random.IoSource = .{ .io = io };
    const random = random_impl.interface();

    const userdata = random.int(u32);

    const nop_message: rmnet.Operation.Message(rmnet.Operation.Nop) = .init(userdata, .{});

    std.log.info("sending nop, userdata={d}", .{userdata});

    socket.send(io, &destination, @ptrCast(&nop_message)) catch |err|
        fatal("send: {t}", .{err});

    var recv_buffer: [1400]u8 align(@alignOf(u64)) = undefined;

    const in_message = socket.receive(io, &recv_buffer) catch |err|
        fatal("receive: {t}", .{err});

    const ExpectedMessage = rmnet.Event.Message(rmnet.Event.Ack);

    if (in_message.data.len != @sizeOf(ExpectedMessage))
        fatal("received invalid packet from server", .{});

    const received: *ExpectedMessage = @ptrCast(recv_buffer[0..in_message.data.len]);

    if (received.header.protocol_version != rmnet.Version.current or
        received.header.event_version != rmnet.Event.Ack.version or
        received.header.event_tag != .ack)
        fatal("received unexpected message from server", .{});

    std.log.info("received ack, userdata={d}", .{userdata});
}

const fatal = std.process.fatal;

const Io = std.Io;
const Init = std.process.Init;

const net = std.Io.net;

const rmio = @import("rmio");
const rmnet = @import("rmnet");

const builtin = @import("builtin");
const std = @import("std");
