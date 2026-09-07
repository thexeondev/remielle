const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const testing = std.testing;

const crlf = "\r\n";

pub const Server = @import("http/Server.zig");

test {
    testing.refAllDecls(Request);
    testing.refAllDecls(Server);
}

pub const Version = enum {
    @"HTTP/1.0",
    @"HTTP/1.1",

    pub const Error = error{HttpVersionUnsupported};

    pub fn parse(slice: []const u8) Version.Error!Version {
        return std.meta.stringToEnum(Version, slice) orelse
            return error.HttpVersionUnsupported;
    }
};

pub const Request = struct {
    line: Line,
    body: [:0]u8,

    pub const ParseHeadersError = error{HttpHeadersInvalid};

    pub const ParseHeadersReadingError = ParseHeadersError || Io.Reader.DelimiterError;

    pub const SizeError = error{HttpRequestOversize};

    pub const Line = struct {
        method: []const u8,
        target: []const u8,
        version: Version,

        pub const ParseError = Request.ParseHeadersReadingError || Version.Error;

        pub fn parse(reader: *Io.Reader) Request.Line.ParseError!Line {
            const line = try takeHeaderLine(reader);
            var tokens = mem.tokenizeScalar(u8, line, ' ');

            const method = tokens.next() orelse return error.HttpHeadersInvalid;
            const target = tokens.next() orelse return error.HttpHeadersInvalid;
            const version_string = tokens.next() orelse return error.HttpHeadersInvalid;

            if (tokens.next() != null) return error.HttpHeadersInvalid;

            const version: Version = try .parse(version_string);

            return .{
                .method = method,
                .target = target,
                .version = version,
            };
        }

        pub fn splitTarget(line: *Request.Line) struct { []const u8, []const u8 } {
            return mem.cutScalar(u8, line.target, '?') orelse
                .{ line.target, "" };
        }

        test parse {
            const bytes =
                "GET /hello/world?param=123 HTTP/1.1\r\n";

            var reader: Io.Reader = .fixed(bytes);
            const parsed: Line = try .parse(&reader);
            try testing.expectEqualStrings(parsed.method, "GET");
            try testing.expectEqualStrings(parsed.target, "/hello/world?param=123");
            try testing.expectEqual(parsed.version, .@"HTTP/1.1");
        }
    };

    pub const Header = struct {
        key: []const u8,
        value: []const u8,

        /// Null indicates an empty line, which indicates end of header bundle.
        pub fn parse(reader: *Io.Reader) Request.ParseHeadersReadingError!?Header {
            const line = try takeHeaderLine(reader);
            if (line.len == 0) return null;

            const key, const value = mem.cut(u8, line, ": ") orelse
                return error.HttpHeadersInvalid;

            return .{ .key = key, .value = value };
        }

        pub const Iterator = struct {
            reader: *Io.Reader,

            pub fn next(it: *Request.Header.Iterator) Request.ParseHeadersReadingError!?Header {
                return try .parse(it.reader);
            }
        };
    };

    pub fn parseQuery(comptime Query: type, query: []const u8) ?Query {
        const Field = std.meta.FieldEnum(Query);
        var seen_fields: std.EnumSet(Field) = .empty;
        var result: Query = undefined;

        var it = mem.splitScalar(u8, query, '&');
        while (it.next()) |entry| {
            const key_string, const value = mem.cutScalar(u8, entry, '=') orelse
                return null;

            const key = std.meta.stringToEnum(Field, key_string) orelse continue;

            switch (key) {
                inline else => |key_comptime| {
                    seen_fields.insert(key_comptime);
                    @field(result, @tagName(key_comptime)) = value;
                },
            }
        }

        return if (seen_fields.eql(.full)) result else null;
    }

    pub const ParseFromSliceError = Request.ParseHeadersError ||
        Version.Error ||
        SizeError ||
        error{UnexpectedEnd};

    pub fn parseFromBuffer(buffer: []u8, readable: usize) ParseFromSliceError!Request {
        var reader: Io.Reader = .{
            .buffer = buffer,
            .seek = 0,
            .end = readable,
            .vtable = Io.Reader.ending_instance.vtable,
        };

        return parseFromBufferReading(&reader) catch |err| switch (err) {
            error.ReadFailed => unreachable, // Io.Reader.fixed is always ending

            error.EndOfStream => return error.UnexpectedEnd,
            error.StreamTooLong => return error.UnexpectedEnd,

            error.HttpHeadersInvalid,
            error.HttpVersionUnsupported,
            error.HttpRequestOversize,
            => |e| return e,
        };
    }

    const ParseReadingError = Request.ParseHeadersReadingError || Version.Error || SizeError;

    fn parseFromBufferReading(reader: *Io.Reader) ParseReadingError!Request {
        const line: Line = try .parse(reader);
        var it: Request.Header.Iterator = .{ .reader = reader };
        var content_length: u64 = 0;

        while (try it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.key, "content-length")) {
                content_length = std.fmt.parseInt(u64, header.value, 10) catch
                    return error.HttpHeadersInvalid;
            }
        }

        // One extra byte to place a sentinel.
        if (reader.buffer.len - reader.seek < content_length + 1)
            return error.HttpRequestOversize;

        if (reader.end - reader.seek < content_length)
            return error.EndOfStream;

        const body = reader.buffer[reader.seek..][0 .. content_length + 1];
        body[content_length] = 0;

        return .{ .line = line, .body = @ptrCast(body[0..content_length]) };
    }

    fn takeHeaderLine(reader: *Io.Reader) Request.ParseHeadersReadingError![]const u8 {
        const line = try reader.takeDelimiterInclusive('\n');
        return mem.cutSuffix(u8, line, crlf) orelse return error.HttpHeadersInvalid;
    }
};
