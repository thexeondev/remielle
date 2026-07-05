bytes: [size]u8,

pub const size: usize = 4096;
pub const initial: *const Xorpad = &.{ .bytes = @embedFile("initial_xorpad").* };

pub const Offset = enum(usize) {
    beginning = 0,
    _,

    pub inline fn offset(value: usize) Offset {
        return @enumFromInt(value);
    }

    pub inline fn advance(o: *Offset, seek: usize) void {
        o.* = @enumFromInt(@intFromEnum(o.*) + seek);
    }
};

pub const Key = enum(u64) {
    _,

    pub const DeriveError = error{
        RandKeyDecryptFail,
    };

    pub fn derive(server_rand_key: u64, client_rand_key_b64: []const u8) DeriveError!Key {
        const client_rand_key = decryptClientRandKey(client_rand_key_b64) orelse
            return error.RandKeyDecryptFail;

        return @enumFromInt(client_rand_key ^ server_rand_key);
    }

    fn decryptClientRandKey(b64: []const u8) ?u64 {
        if (b64.len != block_size_base64)
            return null;

        var ciphertext: [rmcrypt.rsa.block_size]u8 = undefined;

        base64.Decoder.decode(&ciphertext, b64) catch
            return null;

        var plaintext_buf: [rmcrypt.rsa.block_size]u8 = undefined;
        const plaintext = rmcrypt.rsa.server_private_key.decrypt(&ciphertext, &plaintext_buf) orelse
            return null;

        if (plaintext.len != @sizeOf(u64))
            return null;

        return std.mem.readInt(u64, plaintext[0..@sizeOf(u64)], .little);
    }
};

pub fn xor(xp: *const Xorpad, offset: Offset, data: []u8) void {
    for (data, 0..) |*byte, i|
        byte.* ^= xp.bytes[@mod(@intFromEnum(offset) + i, size)];
}

pub fn wrapWriter(xp: *const Xorpad, writer: *Io.Writer) Writer {
    return .init(xp, writer);
}

pub fn wrapReader(xp: *const Xorpad, reader: *Io.Reader, limit: usize) Reader {
    return .init(xp, reader, limit);
}

pub fn fillSeeded(xp: *Xorpad, key: Key) void {
    var mt: rmcrypt.prng.MT19937 = .init(@intFromEnum(key));
    for (0..size >> 3) |i|
        std.mem.writeInt(u64, xp.bytes[i * 8 ..][0..8], mt.get(), .big);
}

pub const Writer = struct {
    xorpad: *const Xorpad,
    buffer_offset: usize,
    offset: Offset,
    nested: *Io.Writer,
    interface: Io.Writer,

    pub fn init(xorpad: *const Xorpad, nested: *Io.Writer) Writer {
        return .{
            .xorpad = xorpad,
            .buffer_offset = nested.end,
            .offset = .beginning,
            .nested = nested,
            .interface = .{
                .buffer = nested.buffer,
                .end = nested.end,
                .vtable = &.{ .drain = drain },
            },
        };
    }

    /// Xors the buffered data.
    /// Updates the underlying `Io.Writer`'s `end` position.
    pub fn deinit(writer: *Writer) void {
        const to_xor = writer.interface.buffer[writer.buffer_offset..writer.interface.end];
        writer.xorpad.xor(writer.offset, to_xor);
        writer.nested.end = writer.interface.end;
    }

    pub fn drain(io_w: *Io.Writer, _: []const []const u8, _: usize) Io.Writer.Error!usize {
        const writer: *Writer = @alignCast(@fieldParentPtr("interface", io_w));

        const to_xor = io_w.buffer[writer.buffer_offset..io_w.end];
        writer.xorpad.xor(writer.offset, to_xor);
        writer.offset.advance(to_xor.len);

        writer.nested.end = io_w.end;
        _ = try writer.nested.vtable.drain(writer.nested, &.{&.{}}, 0);

        io_w.end = writer.nested.end;
        io_w.buffer = writer.nested.buffer;
        writer.buffer_offset = writer.nested.end;

        return 0;
    }
};

pub const Reader = struct {
    xorpad: *const Xorpad,
    offset: Offset,
    nested: *Io.Reader,
    // We also want to make this reader limited (to return EndOfStream when payload is over)
    // without an extra layer of abstraction such as Io.Reader.Limited
    remaining: usize,
    interface: Io.Reader,

    pub fn init(xorpad: *const Xorpad, nested: *Io.Reader, limit: usize) Reader {
        var wrapped: Reader = .{
            .xorpad = xorpad,
            .offset = .beginning,
            .nested = nested,
            .remaining = limit -| (nested.end - nested.seek),
            .interface = .{
                .buffer = nested.buffer[0..@min(nested.seek + limit, nested.buffer.len)],
                .seek = nested.seek,
                .end = @min(nested.seek + limit, nested.end),
                .vtable = &.{
                    .stream = stream,
                    .readVec = readVec,
                    .rebase = rebase,
                },
            },
        };

        const to_xor = wrapped.interface.buffered();
        wrapped.xorpad.xor(wrapped.offset, to_xor);
        wrapped.offset.advance(to_xor.len);

        return wrapped;
    }

    /// Updates nested Reader's `seek` position so it can be used to continue reading
    /// from the point user stopped using wrapped instance.
    pub fn deinit(r: *Reader) void {
        r.nested.seek = r.interface.seek;
    }

    fn stream(io_r: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        try refill(io_r);
        return 0;
    }

    fn readVec(io_r: *Io.Reader, _: [][]u8) Io.Reader.Error!usize {
        try refill(io_r);
        return 0;
    }

    fn rebase(io_r: *Io.Reader, capacity: usize) Io.Reader.RebaseError!void {
        const wrapped: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
        if (wrapped.remaining == 0) return error.EndOfStream;

        if (io_r.seek == io_r.end)
            return refill(io_r);

        const leftover = io_r.end - io_r.seek;
        wrapped.nested.end = io_r.end;
        wrapped.nested.seek = io_r.seek;

        try wrapped.nested.vtable.rebase(wrapped.nested, capacity);

        wrapped.interface.buffer = wrapped.nested.buffer;
        wrapped.interface.seek = wrapped.nested.seek;
        wrapped.interface.end = @min(wrapped.nested.seek + wrapped.remaining, wrapped.nested.end);

        if (wrapped.nested.end - wrapped.nested.seek > leftover) {
            // New data arrived which we have to xor.
            const to_xor = wrapped.interface.buffered()[leftover..];

            wrapped.xorpad.xor(wrapped.offset, to_xor);
            wrapped.offset.advance(to_xor.len);
            wrapped.remaining -|= to_xor.len;
        }
    }

    fn refill(io_r: *Io.Reader) Io.Reader.Error!void {
        if (io_r.end != io_r.seek) return;
        const wrapped: *Reader = @alignCast(@fieldParentPtr("interface", io_r));

        if (wrapped.remaining == 0) return error.EndOfStream;

        wrapped.nested.seek = wrapped.nested.end;

        _ = try wrapped.nested.vtable.readVec(wrapped.nested, &.{});

        wrapped.interface.buffer = wrapped.nested.buffer[0..@min(
            wrapped.nested.seek + wrapped.remaining,
            wrapped.nested.end,
        )];

        wrapped.interface.end = @min(wrapped.nested.seek + wrapped.remaining, wrapped.nested.end);
        wrapped.interface.seek = wrapped.nested.seek;

        const to_xor = wrapped.interface.buffered();

        wrapped.xorpad.xor(wrapped.offset, to_xor);
        wrapped.offset.advance(to_xor.len);
        wrapped.remaining -|= to_xor.len;
    }
};

const block_size_base64 = base64.Encoder.calcSize(rmcrypt.rsa.block_size);

const Io = std.Io;

const base64 = std.base64.standard;

const rmcrypt = @import("rmcrypt");
const std = @import("std");
const Xorpad = @This();
