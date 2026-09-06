pub const Payload = http.Request.Payload(Route);

const namespaces: []const type = &.{
    @import("routes/mdk.zig"),
    @import("routes/combo.zig"),
    @import("routes/account.zig"),
};

pub const Route = Route: {
    var names: []const [:0]const u8 = &.{};
    var values: []const u8 = &.{};
    var i: u8 = 0;

    for (namespaces) |ns| for (@typeInfo(ns).@"struct".decl_names) |decl_name| {
        names = names ++ [1][:0]const u8{decl_name};
        values = values ++ [1]u8{i};
        i += 1;
    };

    break :Route @Enum(u8, .exhaustive, names, @ptrCast(values));
};

pub const Request = struct {
    io: Io,
    gpa: Allocator,
    passwd: *Passwd,
    payload: *const Payload,
    response: *ConcatStream,
};

pub fn process(
    io: Io,
    gpa: Allocator,
    passwd: *Passwd,
    payload: *const Payload,
    response_writer: *Io.Writer,
) !void {
    const path = payload.path orelse {
        try response_writer.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        return;
    };

    // TODO: calculate a sound upper bound.
    var copy_buffer: [2048]u8 = undefined;

    // TODO: calculate a sound upper bound.
    var vectors_buffer: [16][]const u8 = undefined;

    var response_stream: ConcatStream = .init(&copy_buffer, vectors_buffer[1..]);

    const request: Request = .{
        .io = io,
        .gpa = gpa,
        .passwd = passwd,
        .payload = payload,
        .response = &response_stream,
    };

    switch (path) {
        inline else => |route| lookup: inline for (namespaces) |ns| {
            inline for (@typeInfo(ns).@"struct".decl_names) |decl_name|
                if (comptime std.mem.eql(u8, decl_name, @tagName(route))) {
                    try @field(ns, decl_name)(&request);
                    break :lookup;
                };
        },
    }

    var header_buffer: [128]u8 = undefined;
    var header_writer: Io.Writer = .fixed(&header_buffer);

    header_writer.print(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\n\r\n",
        .{response_stream.count()},
    ) catch unreachable;

    vectors_buffer[0] = header_writer.buffered();

    try response_writer.writeVecAll(vectors_buffer[0 .. response_stream.vectors_end + 1]);
}

/// A sink, result of which is a sequence of concatenated buffers.
pub const ConcatStream = struct {
    /// Used for appending non-constant buffers with a temporary lifetime.
    copy_buffer: []u8,
    /// The amount of used space in `copy_buffer`.
    copy_buffer_end: usize,
    /// Concatenated buffers, filled up to `vectors_end`.
    vectors: [][]const u8,
    /// The amount of filled buffers in `vectors`.
    vectors_end: usize,

    pub fn init(
        /// If `copy_buffer.len` is zero, `append` will always fail.
        copy_buffer: []u8,
        vectors: [][]const u8,
    ) ConcatStream {
        return .{
            .copy_buffer = copy_buffer,
            .copy_buffer_end = 0,
            .vectors = vectors,
            .vectors_end = 0,
        };
    }

    pub const ZeroCopyError = error{
        /// Too many buffers concatenated; `vectors` exceeded.
        NoVectorsLeft,
    };

    pub fn appendConstant(cs: *ConcatStream, comptime string: []const u8) ZeroCopyError!void {
        if (cs.vectors.len == cs.vectors_end)
            return error.NoVectorsLeft;

        defer cs.vectors_end += 1;
        cs.vectors[cs.vectors_end] = string;
    }

    pub const AppendError = error{
        /// `copy_buffer` exceeded.
        NoSpaceLeft,
    } || ZeroCopyError;

    pub fn append(cs: *ConcatStream, string: []const u8) AppendError!void {
        if (cs.vectors.len == cs.vectors_end)
            return error.NoVectorsLeft;

        const unused_copy_space = cs.copy_buffer[cs.copy_buffer_end..];
        if (unused_copy_space.len < string.len)
            return error.NoSpaceLeft;

        defer {
            cs.vectors_end += 1;
            cs.copy_buffer_end += string.len;
        }

        const copied = unused_copy_space[0..string.len];
        @memcpy(copied, string);

        cs.vectors[cs.vectors_end] = copied;
    }

    pub fn count(cs: *const ConcatStream) usize {
        var size: usize = 0;
        for (cs.vectors[0..cs.vectors_end]) |data|
            size += data.len;

        return size;
    }
};

const Io = std.Io;
const Passwd = @import("Passwd.zig");
const Allocator = std.mem.Allocator;

const http = @import("http.zig");
const std = @import("std");
