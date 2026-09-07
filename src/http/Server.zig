const Server = @This();

const builtin = @import("builtin");
const is_debug = builtin.optimize == .debug;

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const remielle = @import("../remielle.zig");
const http = remielle.http;

/// `State` and task buffers.
allocation: []align(@alignOf(State)) u8,

pub const Options = struct {
    /// The size of task pool.
    /// Determines limit of concurrent connections.
    task_count: u32,
    /// Receive buffer size.
    /// Determines limit of request size.
    rx_buf_len: usize,
    /// Send buffer size.
    /// Determines limit of response size.
    tx_buf_len: usize,
};

const State = struct {
    group: Io.Group,
    queue: Io.Queue(*Request),
};

pub const InitError = Allocator.Error || Io.ConcurrentError;

pub fn init(
    io: Io,
    gpa: Allocator,
    net_server: *Io.net.Server,
    options: Options,
) InitError!Server {
    const task_buffer_len = options.rx_buf_len + options.tx_buf_len;
    const allocation_size = @sizeOf(State) + (task_buffer_len * options.task_count);
    const allocation = try gpa.alignedAlloc(u8, .of(State), allocation_size);
    errdefer gpa.free(allocation);

    const state: *State = @ptrCast(allocation[0..@sizeOf(State)]);
    const buffers = allocation[@sizeOf(State)..];

    state.* = .{
        .group = .init,
        .queue = .init(&.{}),
    };
    errdefer state.group.cancel(io);

    for (0..options.task_count) |task_index| {
        const task_buffer = buffers[task_buffer_len * task_index ..][0..task_buffer_len];
        try state.group.concurrent(io, Task.run, .{ io, .{
            .req_queue = &state.queue,
            .rx_buffer = task_buffer[0..options.rx_buf_len],
            .tx_buffer = task_buffer[options.rx_buf_len..][0..options.tx_buf_len],
            .net_server = net_server,
        } });
    }

    return .{ .allocation = allocation };
}

/// Stops all the tasks and frees the memory.
/// Not threadsafe.
pub fn deinit(server: *Server, io: Io, gpa: Allocator) void {
    const state: *State = @ptrCast(server.allocation[0..@sizeOf(State)]);
    state.queue.close(io);
    state.group.cancel(io);

    gpa.free(server.allocation);
    server.allocation = undefined;
}

/// Waits for the next request to be received.
/// Threadsafe.
pub fn next(server: *Server, io: Io) Io.Cancelable!*Request {
    const state: *State = @ptrCast(server.allocation[0..@sizeOf(State)]);
    return state.queue.getOne(io) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.Closed => unreachable, // `next` called after `deinit`.
    };
}

pub const Request = struct {
    /// Underlying data.
    data: http.Request,
    /// See `finish`.
    finished: Io.Event,
    /// An instance of `Io.Writer.fixed`.
    response_writer: Io.Writer,

    /// Must be called once the application logic finishes processing this `Request`.
    pub fn finish(request: *Request, io: Io) void {
        request.finished.set(io);
    }

    pub const Status = enum(u16) {
        ok = 200,
        bad_request = 400,
        not_found = 404,

        pub fn phrase(status: Status) []const u8 {
            return switch (status) {
                .ok => "OK",
                .bad_request => "Bad Request",
                .not_found => "Not Found",
            };
        }
    };

    pub const RespondError = error{
        HttpResponseOversize,
    };

    /// Initiates HTTP response.
    /// The returned `Io.Writer` is the sink for response body.
    fn beginResponse(
        request: *Request,
        status: Status,
        content_length: u64,
    ) RespondError!*Io.Writer {
        assert(request.response_writer.end == 0); // tried to `respond` multiple times.
        request.response_writer.print(
            "HTTP/1.1 {d} {s}\r\nConnection: close\r\nContent-Length: {d}\r\nContent-Type: application/json\r\n\r\n",
            .{ @backingInt(status), status.phrase(), content_length },
        ) catch |err| switch (err) {
            error.WriteFailed => return error.HttpResponseOversize,
        };

        return &request.response_writer;
    }

    pub fn respondString(
        request: *Request,
        status: Status,
        body: []const u8,
    ) RespondError!void {
        const writer = try request.beginResponse(status, body.len);
        writer.writeAll(body) catch |err| switch (err) {
            error.WriteFailed => return error.HttpResponseOversize,
        };
    }

    pub fn respondPrint(
        request: *Request,
        status: Status,
        comptime fmt: []const u8,
        args: anytype,
    ) RespondError!void {
        const content_length = std.fmt.count(fmt, args);
        const writer = try request.beginResponse(status, content_length);
        writer.print(fmt, args) catch |err| switch (err) {
            error.WriteFailed => return error.HttpResponseOversize,
        };
    }
};

const Task = struct {
    req_queue: *Io.Queue(*Request),
    rx_buffer: []u8,
    tx_buffer: []u8,
    net_server: *Io.net.Server,

    fn run(io: Io, context: Task) Io.Cancelable!void {
        while (true) if (context.net_server.accept(io)) |stream| {
            defer stream.close(io);
            serveStream(io, &context, stream) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => continue,
            };
        } else |err| switch (err) {
            error.Canceled => |e| return e,
            else => continue,
        };
    }

    fn serveStream(io: Io, context: *const Task, stream: Io.net.Stream) !void {
        var read_n: usize = 0;

        const data: http.Request = request: while (read_n < context.rx_buffer.len) {
            var unread_vec: [1][]u8 = .{context.rx_buffer[read_n..]};
            const read_result = try io.operate(.{ .net_read = .{
                .socket_handle = stream.socket.handle,
                .data = &unread_vec,
            } });

            const read_more = try read_result.net_read;
            if (read_more == 0) return; // connection closed

            read_n += read_more;

            break :request http.Request.parseFromBuffer(
                context.rx_buffer,
                read_n,
            ) catch |err| switch (err) {
                error.UnexpectedEnd => continue, // more to receive
                else => |e| return e,
            };
        } else return;

        var request: Request = .{
            .data = data,
            .finished = .unset,
            .response_writer = .fixed(context.tx_buffer),
        };

        try context.req_queue.putOne(io, &request);
        try request.finished.wait(io);

        var write_remaining = request.response_writer.buffered();
        while (write_remaining.len != 0) {
            const write_result = try io.operate(.{ .net_write = .{
                .socket_handle = stream.socket.handle,
                .data = &.{write_remaining},
            } });

            const write_consumed = try write_result.net_write;
            write_remaining = write_remaining[write_consumed..];
        }
    }
};
