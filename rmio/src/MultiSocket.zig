count: u32,
sockets: *Sockets,
batch: Io.Batch,

pub const Context = struct {
    address: net.IpAddress,
    message: net.IncomingMessage,
    buffer: []u8,
};

/// Trailing:
/// * `handles: [len]Socket.Handle`
/// * `storage: [len]Io.Operation.Storage`
/// * `contexts: [len]Context`
pub const Sockets = extern struct {
    capacity: u32,

    pub fn handles(sockets: *Sockets) []Socket.Handle {
        const base: usize = @intFromPtr(sockets);
        const ptr: [*]Socket.Handle = @ptrFromInt(mem.alignForward(
            usize,
            base + @sizeOf(Sockets),
            @alignOf(Socket.Handle),
        ));

        return ptr[0..sockets.capacity];
    }

    pub fn storage(sockets: *Sockets) []Io.Operation.Storage {
        const prev = sockets.handles();
        const ptr: [*]Io.Operation.Storage = @ptrFromInt(mem.alignForward(
            usize,
            @intFromPtr(prev.ptr + prev.len),
            @alignOf(Io.Operation.Storage),
        ));

        return ptr[0..sockets.capacity];
    }

    pub fn contexts(sockets: *Sockets) []Context {
        const prev = sockets.storage();
        const ptr: [*]Context = @ptrFromInt(mem.alignForward(
            usize,
            @intFromPtr(prev.ptr + prev.len),
            @alignOf(Context),
        ));

        return ptr[0..sockets.capacity];
    }
};

pub fn Buffer(comptime n: usize) type {
    return extern struct {
        capacity: u32,
        handles: [n]Socket.Handle,
        storage: [n][@sizeOf(Io.Operation.Storage)]u8 align(@alignOf(Io.Operation.Storage)),
        contexts: [n][@sizeOf(Context)]u8 align(@alignOf(Context)),

        pub fn toSockets(buffer: *@This()) *Sockets {
            buffer.capacity = n;
            return @ptrCast(buffer);
        }
    };
}

/// See `Buffer` for convenience API to obtain the `sockets` parameter.
pub fn init(ms: *MultiSocket, sockets: *Sockets, buffers: []const []u8) void {
    const contexts = sockets.contexts();

    for (contexts, buffers) |*context, buffer|
        context.* = .{
            .address = undefined,
            .message = .init,
            .buffer = buffer,
        };

    ms.* = .{
        .count = 0,
        .sockets = sockets,
        .batch = .init(sockets.storage()),
    };
}

pub fn deinit(ms: *MultiSocket, io: Io) void {
    ms.batch.cancel(io);
    io.vtable.netClose(io.userdata, ms.sockets.handles()[0..ms.count]);
}

pub fn bind(ms: *MultiSocket, io: Io, address: net.IpAddress) !usize {
    std.debug.assert(ms.count < ms.sockets.capacity);

    const socket = try address.bind(io, .{ .mode = .dgram, .protocol = .udp });
    errdefer comptime unreachable;

    const index = ms.count;
    defer ms.count += 1;

    ms.sockets.handles()[index] = socket.handle;
    const context = &ms.sockets.contexts()[index];

    context.address = socket.address;

    ms.batch.addAt(@intCast(index), .{ .net_receive = .{
        .socket_handle = socket.handle,
        .message_buffer = (&context.message)[0..1],
        .data_buffer = context.buffer,
        .flags = .{},
    } });

    return index;
}

pub const ReceiveError = Io.Batch.AwaitConcurrentError;

pub const SocketCompletion = struct {
    socket_index: usize,
    result: union(enum) {
        err: Io.Operation.NetReceive.Error,
        message: Io.net.IncomingMessage,
    },
};

/// Wait until at least one socket receives a message.
pub fn receive(ms: *MultiSocket, io: Io) ReceiveError!SocketCompletion {
    while (true) {
        while (ms.batch.next()) |completion| {
            const context = &ms.sockets.contexts()[completion.index];

            defer ms.batch.addAt(completion.index, .{ .net_receive = .{
                .socket_handle = ms.sockets.handles()[completion.index],
                .message_buffer = (&context.message)[0..1],
                .data_buffer = context.buffer,
                .flags = .{},
            } });

            const maybe_err, const n = completion.result.net_receive;

            if (maybe_err) |err| switch (err) {
                error.Canceled => unreachable, // what the FUCK `Canceled` is doing here..
                else => |e| return .{
                    .socket_index = completion.index,
                    .result = .{ .err = e },
                },
            };

            std.debug.assert(n == 1);

            return .{
                .socket_index = completion.index,
                .result = .{ .message = context.message },
            };
        }

        try ms.batch.awaitConcurrent(io, .none);
    }
}

pub fn get(ms: *MultiSocket, index: usize) net.Socket {
    return .{
        .handle = ms.sockets.handles()[index],
        .address = ms.sockets.contexts()[index].address,
    };
}

const Io = std.Io;
const Socket = net.Socket;

const mem = std.mem;
const net = std.Io.net;

const std = @import("std");
const MultiSocket = @This();
