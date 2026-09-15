const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const remielle = @import("remielle.zig");
const protobuf = remielle.protobuf;

pub const Command = struct {
    pub const overhead = 16;

    pub const head_magic: u32 = 0x1234567;
    pub const tail_magic: u32 = 0x89ABCDEF;

    id: u16,
    head: []u8,
    body: []u8,

    pub const Decoded = struct {
        command: Command,
        consumed_bytes: usize,
    };

    pub const DecodeError = error{
        MagicNumberMismatch,
    };

    pub fn decode(bytes: []u8) DecodeError!?Decoded {
        if (bytes.len < overhead) return null;

        if (mem.readInt(u32, bytes[0..4], .big) != head_magic)
            return error.MagicNumberMismatch;

        const cmd_id = mem.readInt(u16, bytes[4..6], .big);
        const head_len = mem.readInt(u16, bytes[6..8], .big);
        const body_len = mem.readInt(u32, bytes[8..12], .big);

        if (bytes.len < overhead + head_len + body_len)
            return null;

        if (mem.readInt(u32, bytes[12 + head_len + body_len ..][0..4], .big) != tail_magic)
            return error.MagicNumberMismatch;

        return .{
            .command = .{
                .id = cmd_id,
                .head = bytes[12..][0..head_len],
                .body = bytes[12 + head_len ..][0..body_len],
            },
            .consumed_bytes = overhead + head_len + body_len,
        };
    }

    pub fn encode(
        writer: *Io.Writer,
        id: u16,
        head: protobuf.stable.PacketHead,
        body: anytype,
        xorpad: *const [4096]u8,
    ) Io.Writer.Error!void {
        const head_len = protobuf.encodingLength(.stable, head);
        const body_len = protobuf.encodingLength(.main, body);
        const full_len = overhead + head_len + body_len;
        const buffer = try writer.writableSlice(full_len);

        mem.writeInt(u32, buffer[0..4], head_magic, .big);
        mem.writeInt(u16, buffer[4..6], id, .big);
        mem.writeInt(u16, buffer[6..8], @intCast(head_len), .big);
        mem.writeInt(u32, buffer[8..12], @intCast(body_len), .big);

        const head_buffer = buffer[12..][0..head_len];
        var head_writer: Io.Writer = .fixed(head_buffer);
        protobuf.encode(.stable, &head_writer, head) catch unreachable;

        const body_buffer = buffer[12 + head_len ..][0..body_len];
        var body_writer: Io.Writer = .fixed(body_buffer);
        protobuf.encode(.main, &body_writer, body) catch unreachable;

        xor(body_buffer, xorpad);

        mem.writeInt(u32, buffer[12 + head_len + body_len ..][0..4], tail_magic, .big);
    }
};

pub fn xor(buffer: []u8, xorpad: *const [4096]u8) void {
    for (buffer, 0..) |*byte, index|
        byte.* ^= xorpad[index % xorpad.len];
}

pub fn getDecryptVector(vector: *[4096]u8, seed: u64) void {
    var mt: remielle.prng.MT19937 = .init(seed);

    for (0..512) |i|
        mem.writeInt(u64, vector[i * 8 ..][0..8], mt.get(), .big);
}
