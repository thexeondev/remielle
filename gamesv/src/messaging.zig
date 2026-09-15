const std = @import("std");
const Io = std.Io;

const remielle = @import("remielle");
const protobuf = remielle.protobuf;

const log = std.log.scoped(.@"remielle-gamesv::messaging");

pub const handlers = @import("messaging/handlers.zig");

pub const SendError = Io.Writer.Error;

pub const Ack = enum(u32) {
    notify = 0,
    _,

    pub fn ack(id: u32) Ack {
        return @fromBackingInt(@intCast(id));
    }
};

pub const Sink = struct {
    packet_id_counter: *u32,
    xorpad: *const [4096]u8,
    writer: *Io.Writer,
};

pub fn send(
    sink: *const Sink,
    ack: Ack,
    message: anytype,
) SendError!void {
    const cmd_id = (comptime protobuf.cmdId(@TypeOf(message))) orelse return;

    const packet_id = sink.packet_id_counter.*;
    defer sink.packet_id_counter.* += 1;

    const head: protobuf.stable.PacketHead = .{
        .packet_id = packet_id,
        .ack_packet_id = @backingInt(ack),
    };

    try remielle.protocol.Command.encode(sink.writer, cmd_id, head, message, sink.xorpad);
}

pub fn sendDummy(
    sink: *const Sink,
    ack: Ack,
) SendError!void {
    const DummyCmd = comptime DummyCmd: {
        const ns = protobuf.Descriptors.main.namespace();
        const name = @import("config").dummy_cmd;
        if (!@hasDecl(ns, name))
            @compileError("the `dummy_cmd` is invalid");

        break :DummyCmd @field(ns, name);
    };

    const dummy: DummyCmd = .{};
    return send(sink, ack, dummy);
}
