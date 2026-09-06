buffer: *const [size]u8,

pub const size: usize = 20;

pub const Kind = enum(u64) {
    connect = 0xFFFFFFFFFF,
    send_back_conv = 0x14514514545,
    disconnect = 0x19419419494,
    _,
};

pub fn encode(buffer: *[size]u8, k: Kind, conv_id: kcp.ConvId, token: kcp.Token.Unchecked, userdata: u32) void {
    writeInt(u32, buffer[0..4], @truncate(@backingInt(k) >> 32), .big);
    writeInt(u32, buffer[4..8], @backingInt(conv_id), .big);
    writeInt(u32, buffer[8..12], @backingInt(token), .big);
    writeInt(u32, buffer[12..16], userdata, .big);
    writeInt(u32, buffer[16..20], @truncate(@backingInt(k)), .big);
}

pub inline fn kind(control: Control) Kind {
    const head: u64 = readInt(u32, control.buffer[0..4], .big);
    const tail: u64 = readInt(u32, control.buffer[16..20], .big);

    return @fromBackingInt(@intCast((head << 32) | tail));
}

pub inline fn conv(control: Control) kcp.ConvId {
    return @fromBackingInt(@intCast(readInt(u32, control.buffer[4..8], .big)));
}

pub inline fn isToken(control: Control, token: kcp.Token) bool {
    return readInt(u32, control.buffer[8..12], .big) == @backingInt(token);
}

const readInt = std.mem.readInt;
const writeInt = std.mem.writeInt;

const kcp = @import("../kcp.zig");
const std = @import("std");
const Control = @This();
