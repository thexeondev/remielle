pub const size: usize = 28;

conv_id: kcp.ConvId,
token: kcp.Token.Unchecked,
cmd: Cmd,
frg: Fragment,
wnd: u16,
ts: kcp.Timeval,
sn: u32,
una: u32,
len: u32,

pub const Cmd = enum(u8) {
    push = 81,
    ack = 82,
    wask = 83,
    wins = 84,
};

pub const Fragment = enum(u8) {
    last = 0,
    _,
};

pub const DecodeError = error{InvalidCmd};

pub fn decode(bytes: *const [size]u8) DecodeError!Header {
    const cmd = std.enums.fromInt(Cmd, bytes[8]) orelse return error.InvalidCmd;
    errdefer comptime unreachable;

    return .{
        .conv_id = @fromBackingInt(@intCast(readInt(u32, bytes[0..4], .little))),
        .token = @fromBackingInt(@intCast(readInt(u32, bytes[4..8], .little))),
        .cmd = cmd,
        .frg = @fromBackingInt(@intCast(bytes[9])),
        .wnd = readInt(u16, bytes[10..12], .little),
        .ts = .{ .milliseconds = readInt(u32, bytes[12..16], .little) },
        .sn = readInt(u32, bytes[16..20], .little),
        .una = readInt(u32, bytes[20..24], .little),
        .len = readInt(u32, bytes[24..28], .little),
    };
}

pub fn encode(header: *const Header, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeInt(u32, @backingInt(header.conv_id), .little);
    try writer.writeInt(u32, @backingInt(header.token), .little);
    try writer.writeByte(@backingInt(header.cmd));
    try writer.writeByte(@backingInt(header.frg));
    try writer.writeInt(u16, header.wnd, .little);
    try writer.writeInt(u32, header.ts.milliseconds, .little);
    try writer.writeInt(u32, header.sn, .little);
    try writer.writeInt(u32, header.una, .little);
    try writer.writeInt(u32, header.len, .little);
}

const readInt = std.mem.readInt;

const Io = std.Io;

const kcp = @import("../kcp.zig");
const std = @import("std");
const Header = @This();
