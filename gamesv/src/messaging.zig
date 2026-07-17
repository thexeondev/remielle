const remielle = @import("remielle");
const protobuf = remielle.protobuf;

const log = std.log.scoped(.@"remielle-gamesv::messaging");

pub const handlers = @import("messaging/handlers.zig");
pub const notifiers = @import("messaging/notifiers.zig");
pub const Xorpad = @import("messaging/Xorpad.zig");

pub const Header = struct {
    pub const magic: [4]u8 = .{ 0x01, 0x23, 0x45, 0x67 };
    pub const size: usize = 12;

    cmd_id: u16,
    head_len: u16,
    body_len: u32,

    pub const DecodeError = error{InvalidMagic};

    pub fn decode(bytes: *const [size]u8) DecodeError!Header {
        if (!std.mem.eql(u8, bytes[0..4], &magic))
            return error.InvalidMagic;

        errdefer comptime unreachable;

        return .{
            .cmd_id = readInt(u16, bytes[4..6], .big),
            .head_len = readInt(u16, bytes[6..8], .big),
            .body_len = readInt(u32, bytes[8..12], .big),
        };
    }
};

pub fn encodingLength(head: protobuf.stable.PacketHead, body: anytype) usize {
    return protobuf.encodingLength(.stable, head) + protobuf.encodingLength(.main, body) + 16;
}

pub fn decodePacketHead(bytes: []const u8) ?protobuf.stable.PacketHead {
    var reader: Io.Reader = .fixed(bytes);
    return protobuf.decode(.stable, protobuf.stable.PacketHead, .failing, &reader) catch null;
}

pub fn encode(
    writer: *Io.Writer,
    xorpad: *const Xorpad,
    cmd_id: u16,
    head: protobuf.stable.PacketHead,
    body: anytype,
) Io.Writer.Error!void {
    try writer.writeAll(&Header.magic);
    try writer.writeInt(u16, cmd_id, .big);
    try writer.writeInt(u16, @intCast(protobuf.encodingLength(.stable, head)), .big);
    try writer.writeInt(u32, @intCast(protobuf.encodingLength(.main, body)), .big);
    try protobuf.encode(.stable, writer, head);

    var xw = xorpad.wrapWriter(writer);
    try protobuf.encode(.main, &xw.interface, body);
    xw.deinit();

    try writer.writeInt(u32, 0x89ABCDEF, .big);
}

pub fn expectFirstPacket(
    /// Used for copying strings for PlayerGetTokenCsReq decoding
    /// ideally, we should introduce an option to protobuf decoder
    /// for not copying strings which would be applicable in this case.
    string_buffer: []u8,
    /// Packet contents, *not* including kcp header
    data: []u8,
) !protobuf.main.PlayerGetTokenCsReq {
    if (data.len < Header.size)
        return error.SizeMismatch;

    const header = try Header.decode(data[0..Header.size]);
    if (header.head_len + header.body_len > data.len - Header.size)
        return error.SizeMismatch;

    if (header.cmd_id != protobuf.main_desc.PlayerGetTokenCsReq.cmd_id) {
        log.debug("received unexpected first cmd_id: {d}", .{header.cmd_id});
        return error.UnexpectedCmdId;
    }

    const body = data[Header.size + header.head_len ..][0..header.body_len];
    Xorpad.initial.xor(.beginning, body);

    var fba: heap.FixedBufferAllocator = .init(string_buffer);
    var br: Io.Reader = .fixed(body);

    return protobuf.decode(.main, protobuf.main.PlayerGetTokenCsReq, fba.allocator(), &br) catch
        return error.MalformedPayload;
}

pub const SendError = error{MessageOversize};

pub const Ack = enum(u32) {
    notify = 0,
    _,

    pub fn ack(id: u32) Ack {
        return @enumFromInt(id);
    }
};

pub fn send(
    multi_conversation: *kcp.MultiConversation,
    clients: *Clients,
    destination_index: u32,
    ack: Ack,
    message: anytype,
) SendError!void {
    const cmd_id = (comptime protobuf.cmdId(@TypeOf(message))) orelse return;

    const head: protobuf.stable.PacketHead = .{
        .packet_id = clients.getPtr(.packet_counter, destination_index).nextId(),
        .ack_packet_id = @intFromEnum(ack),
    };

    const length = encodingLength(head, message);
    var writer = try multi_conversation.writer(destination_index, length);

    encode(
        &writer.interface,
        clients.getPtr(.xorpad, destination_index),
        cmd_id,
        head,
        message,
    ) catch unreachable;
}

pub fn sendDummy(
    multi_conversation: *kcp.MultiConversation,
    clients: *Clients,
    destination_index: u32,
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
    return send(multi_conversation, clients, destination_index, ack, dummy);
}

const readInt = std.mem.readInt;

const Io = std.Io;
const Clients = Server.Clients;

const heap = std.heap;

const kcp = @import("kcp.zig");
const Server = @import("Server.zig");

const rmcrypt = @import("rmcrypt");
const std = @import("std");
