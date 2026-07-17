const loopback = Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;

test "netBind with unspecified port" {
    if (!RemiellIo.supported) return error.SkipZigTest;

    var rmio: RemiellIo = try .init(testing.allocator, .{
        .coroutine_limit = .limited(1),
        .stack_size = 1024 * 1024,
    });

    defer rmio.deinit();
    const io = rmio.io();

    const socket = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);

    try testing.expect(socket.address.ip4.port != 0);
}

test "Batch netReceive" {
    if (!RemiellIo.supported) return error.SkipZigTest;

    var rmio: RemiellIo = try .init(testing.allocator, .{
        .coroutine_limit = .nothing,
        .stack_size = 0,
    });

    defer rmio.deinit();
    const io = rmio.io();

    var receivers: [2]Io.net.Socket = undefined;

    receivers[0] = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer receivers[0].close(io);

    receivers[1] = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer receivers[1].close(io);

    const sender = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sender.close(io);

    var message_buf: [2]Io.net.IncomingMessage = undefined;
    var receive_bufs: [2][1400]u8 = undefined;

    var batch_storage: [2]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&batch_storage);
    defer batch.cancel(io);

    for (receivers, &message_buf, &receive_bufs, 0..) |socket, *msg, *recv_buf, index|
        batch.addAt(@intCast(index), .{ .net_receive = .{
            .socket_handle = socket.handle,
            .message_buffer = msg[0..1],
            .data_buffer = recv_buf,
            .flags = .{},
        } });

    try sender.send(io, &receivers[1].address, "Hi");

    try batch.awaitConcurrent(io, .none);

    const completion = batch.next().?;

    try testing.expectEqual(completion.index, 1);
    try testing.expectEqual(completion.result.net_receive, .{ null, 1 });
    try testing.expectEqualSlices(u8, message_buf[1].data, "Hi");

    try testing.expect(batch.next() == null);
}

test "Batch.awaitConcurrent fails without memory allocations but Batch.awaitAsync succeeds" {
    if (!RemiellIo.supported) return error.SkipZigTest;

    var rmio: RemiellIo = try .init(.failing, .{
        .coroutine_limit = .nothing,
        .stack_size = 0,
    });

    defer rmio.deinit();
    const io = rmio.io();

    const receiver = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer receiver.close(io);

    const sender = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sender.close(io);

    var message: Io.net.IncomingMessage = undefined;
    var buffer: [1400]u8 = undefined;

    var batch_storage: [1]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&batch_storage);
    defer batch.cancel(io);

    batch.addAt(0, .{ .net_receive = .{
        .socket_handle = receiver.handle,
        .message_buffer = (&message)[0..1],
        .data_buffer = &buffer,
        .flags = .{},
    } });

    try sender.send(io, &receiver.address, "heapless");

    try testing.expectError(error.ConcurrencyUnavailable, batch.awaitConcurrent(io, .none));

    try batch.awaitAsync(io);

    const completion = batch.next().?;
    try testing.expectEqual(completion.result.net_receive, .{ null, 1 });
    try testing.expectEqualSlices(u8, message.data, "heapless");
}

test "futex operations: Io.Queue with an empty buffer" {
    if (!RemiellIo.supported) return error.SkipZigTest;

    var rmio: RemiellIo = try .init(testing.allocator, .{
        .coroutine_limit = .limited(1),
        .stack_size = 1024 * 1024,
    });

    defer rmio.deinit();
    const io = rmio.io();

    var queue: Io.Queue(u8) = .init(&.{});
    var consumer = try io.concurrent(queueConsumer, .{ io, &queue });

    var i: u8 = 1;

    while (i <= 5) : (i += 1)
        try queue.putOne(io, i);

    try testing.expectError(error.Canceled, consumer.cancel(io));
}

fn queueConsumer(io: Io, queue: *Io.Queue(u8)) !void {
    var i: u8 = 1;

    while (i <= 5) : (i += 1)
        try testing.expectEqual(i, queue.getOne(io));

    const get_result = queue.getOne(io);
    try testing.expectError(error.Canceled, get_result);

    _ = try get_result;
}

const Io = std.Io;

const testing = std.testing;

const RemiellIo = @import("../RemiellIo.zig");
const std = @import("std");
