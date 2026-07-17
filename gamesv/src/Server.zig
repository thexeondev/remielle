const remielle = @import("remielle");
const mem = remielle.mem;
const MultiSocket = remielle.io.MultiSocket;

const log = std.log.scoped(.@"remielle-gamesv");

pub const Socket = enum(usize) {
    game,
    control,

    pub const count = 2;

    pub inline fn toIndex(socket: Socket) usize {
        return @intFromEnum(socket);
    }

    pub inline fn fromIndex(index: usize) Socket {
        return @enumFromInt(index);
    }
};

/// Used for persistent allocations that are recycled by using internal mechanisms.
/// Has the same lifetime as the `Server` itself.
resource_arena: heap.ArenaAllocator,
/// Used for allocations that have lifetime of a single handler pipeline pass.
resettable_arena: heap.ArenaAllocator,
/// Set of connectionless sockets, as defined by `Socket`.
sockets: *MultiSocket,
/// Initialized at startup.
assets: *const Assets,
persistent: *Persistent,
/// Indexes into arrays in this structure correspond to indexes in `conv_map`.
multi_conversation: kcp.MultiConversation,
/// Per-client, network-related variables that are not part of the `kcp` layer.
clients: Clients,
/// Per-client logic properties.
properties: logic.Properties.List,
/// Counts `kcp.Control.Kind.connect` requests to assign an ID for each client.
conv_counter: kcp.ConvId.Counter,
/// Active conversation IDs.
/// The index of each entry corresponds to index of resources associated
/// with the conversation.
///
/// See also:
/// * `kcp.MultiConversation`
/// * `logic.Properties`
conv_map: array_hash_map.Auto(kcp.ConvId, void),
/// Active player UIDs.
/// The index of each entry corresponds to index of resources associated
/// with the player session.
///
/// See also:
/// * `kcp.MultiConversation`
/// * `logic.Properties`
uid_map: array_hash_map.Auto(u32, void),
/// Used to randomize tokens derived from source address and conversation ID.
/// See also:
/// * `kcp.ConvId`
/// * `kcp.Token`
conv_random: u64,
/// Decreased on each new connection and increased on each disconnect.
/// When `nothing` is set, `onAuthSucceeded` returns `error.SessionLimitExceeded`.
session_limit: Limit,

pub const Client = struct {
    /// Used for assigning the server-to-client `PacketHead.packet_id`.
    packet_counter: PacketCounter,
    xorpad: messaging.Xorpad,
    /// The remote address of the client.
    addr: net.IpAddress,

    pub const PacketCounter = enum(u32) {
        init = 1,
        _,

        pub fn nextId(counter: *PacketCounter) u32 {
            defer counter.* = @enumFromInt(1 +% @intFromEnum(counter.*));
            return @intFromEnum(counter.*);
        }
    };
};

pub const Clients = mem.RemielleArrayList(mem.suggestBucketSize(64, Client), Client, u32);

pub const Frame = struct {
    /// The index of resources associated with the client this `Frame` is originated from.
    target_index: u32,
    /// Wall-clock time of the moment this `Frame` was constructed.
    time: Timestamp,
    /// Same as `Server.clients`
    clients: *Clients,
    /// Same as `Server.assets`
    assets: *const Assets,
    /// Same as `Server.persistent.calendar`
    calendar: *const logic.Calendar,
    /// Same as `Server.properties`
    properties: *logic.Properties.List,
    /// Same as `Server.multi_conversation`
    multi_conversation: *kcp.MultiConversation,

    pub inline fn player(frame: *const Frame) logic.Properties.Player {
        return @enumFromInt(frame.target_index);
    }
};

pub fn init(
    gpa: Allocator,
    csprng: Random,
    sockets: *MultiSocket,
    assets: *const Assets,
    persistent: *Persistent,
    session_limit: Limit,
) Server {
    return .{
        .resource_arena = .init(gpa),
        .resettable_arena = .init(gpa),
        .sockets = sockets,
        .assets = assets,
        .multi_conversation = .init,
        .conv_counter = .init,
        .conv_map = .empty,
        .uid_map = .empty,
        .clients = .empty,
        .properties = .empty,
        .conv_random = csprng.int(u64),
        .persistent = persistent,
        .session_limit = session_limit,
    };
}

pub fn deinit(server: *Server) void {
    server.resource_arena.deinit();
    server.resettable_arena.deinit();
}

pub const ControlPacketStatus = union(enum) {
    nothing: void,
    disconnect: kcp.ConvId,
};

pub fn receiveControlPacket(
    server: *Server,
    from: *const net.IpAddress,
    ctl: kcp.Control,
    out: *?[kcp.Control.size]u8,
) ControlPacketStatus {
    switch (ctl.kind()) {
        .connect => {
            const conv_id = server.conv_counter.next();
            const token: kcp.Token = .init(&.{
                .random = server.conv_random,
                .conv_id = conv_id,
                .addr = @bitCast(from.ip4.bytes),
            });

            out.* = @as([kcp.Control.size]u8, undefined);
            kcp.Control.encode(&out.*.?, .send_back_conv, conv_id, token.downgrade(), 0);

            return .nothing;
        },
        .disconnect => {
            const conv_id = ctl.conv();
            const token: kcp.Token = .init(&.{
                .random = server.conv_random,
                .conv_id = conv_id,
                .addr = @bitCast(from.ip4.bytes),
            });

            if (!ctl.isToken(token)) return .nothing;

            out.* = @as([kcp.Control.size]u8, undefined);
            kcp.Control.encode(&out.*.?, .disconnect, conv_id, token.downgrade(), 0);

            return .{ .disconnect = conv_id };
        },
        .send_back_conv, _ => return .nothing, // Clients should not send this
    }
}

pub fn onAuthSucceeded(
    server: *Server,
    from: *const net.IpAddress,
    first_packet: []u8,
    conv_id: kcp.ConvId,
    token: kcp.Token,
    current_time: Timestamp,
    key: messaging.Xorpad.Key,
    auth_response: rmpb.main.PlayerGetTokenScRsp,
) !u32 {
    server.session_limit = switch (server.session_limit) {
        .unlimited => .unlimited,
        .nothing => return error.SessionLimitExceeded,
        _ => |limit| limit.subtract(1).?,
    };

    errdefer server.increaseLimit();

    const resource_arena = server.resource_arena.allocator();

    const client = try server.multi_conversation.create(resource_arena, conv_id, token, current_time);
    errdefer server.multi_conversation.swapRemove(client);

    // ACK the packet at kcp level
    server.multi_conversation.fillAt(client, first_packet) catch
        return error.InvalidFirstPacket;

    _ = server.multi_conversation.reader(client) orelse
        return error.InvalidFirstPacket;

    server.multi_conversation.discardAt(client);

    const length = messaging.encodingLength(.init, auth_response);
    var writer = try server.multi_conversation.writer(client, length);

    const cmd_id = comptime rmpb.cmdId(rmpb.main.PlayerGetTokenScRsp).?;
    messaging.encode(&writer.interface, .initial, cmd_id, .init, auth_response) catch unreachable;

    try server.conv_map.put(resource_arena, conv_id, {});
    errdefer _ = server.conv_map.swapRemove(conv_id);

    try server.uid_map.put(resource_arena, auth_response.uid, {});
    errdefer _ = server.uid_map.swapRemove(auth_response.uid);

    const index = try server.addClient(from.*, key);
    log.debug("player from {f} has logged in into account with uid {d}", .{ from, auth_response.uid });

    return index;
}

pub const ReceiveStatus = union(enum) {
    success: void,
    /// The conversation ID and token are valid,
    /// but the authentication is not finished yet,
    /// this might be the first packet after connection request.
    unauthenticated: struct { header: kcp.Header, token: kcp.Token },
};

pub fn receiveKcpPacket(
    server: *Server,
    time: Timestamp,
    from: *const net.IpAddress,
    buffer: []u8,
) !ReceiveStatus {
    const kcp_header = kcp.Header.decode(buffer[0..kcp.Header.size]) catch
        return error.MalformedPacket;

    if (kcp_header.conv_id == .none)
        return error.MalformedPacket;

    if (buffer.len < kcp_header.len + kcp.Header.size)
        return error.MalformedPacket;

    const token = kcp_header.token.upgrade(
        server.conv_random,
        @bitCast(from.ip4.bytes),
        kcp_header.conv_id,
    ) orelse return error.InvalidToken;

    const client: u32 = @intCast(server.conv_map.getIndex(kcp_header.conv_id) orelse
        return .{ .unauthenticated = .{ .header = kcp_header, .token = token } });

    server.multi_conversation.fillAt(client, buffer) catch
        return error.FillFailed;

    const frame: Frame = .{
        .target_index = client,
        .time = time,
        .assets = server.assets,
        .clients = &server.clients,
        .properties = &server.properties,
        .calendar = &server.persistent.calendar,
        .multi_conversation = &server.multi_conversation,
    };

    while (true) {
        var reader = server.multi_conversation.reader(client) orelse break;
        defer server.multi_conversation.discardAt(client);
        defer _ = server.resettable_arena.reset(.retain_capacity);

        messaging.handlers.process(
            server.resettable_arena.allocator(),
            &frame,
            &reader.interface,
        ) catch |err| {
            log.err("failed to process message: {t}", .{err});
            break;
        };
    }

    return .success;
}

fn addClient(
    server: *Server,
    addr: net.IpAddress,
    key: messaging.Xorpad.Key,
) !u32 {
    const index = try server.clients.addOne();
    const properties_index = try server.properties.addOne();

    std.debug.assert(index == properties_index);

    server.clients.getPtr(.packet_counter, index).* = .init;
    server.clients.getPtr(.addr, index).* = addr;
    server.clients.getPtr(.xorpad, index).fillSeeded(key);

    return index;
}

fn increaseLimit(server: *Server) void {
    server.session_limit = switch (server.session_limit) {
        .unlimited => .unlimited,
        .nothing, _ => |limit| @enumFromInt(limit.toInt().? + 1),
    };
}

pub fn release(server: *Server, client: u32) void {
    server.conv_map.swapRemoveAt(client);
    server.uid_map.swapRemoveAt(client);
    server.multi_conversation.swapRemove(client);
    server.clients.swapRemove(client);
    server.properties.swapRemove(client);

    server.increaseLimit();
}

pub fn savePlayer(
    server: *Server,
    io: Io,
    index: u32,
) void {
    const arena = server.resettable_arena.allocator();
    defer _ = server.resettable_arena.reset(.retain_capacity);

    const uid = server.uid_map.keys()[index];

    const player_save = logic.Properties.toPlayerSave(
        &server.properties,
        arena,
        @enumFromInt(index),
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            // TODO: get rid of protobuf for saves to avoid this error.
            log.err("ran out of memory while constructing save for UID {d}", .{uid});
            return;
        },
    };

    const old_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_cancel_protection);

    server.persistent.savePlayer(io, uid, player_save) catch |err| switch (err) {
        error.Canceled => unreachable, // blocked
        else => |e| log.err("failed to save player with UID {d}: {t}", .{ uid, e }),
    };
}

pub fn loadPlayerProperties(
    server: *Server,
    io: Io,
    uid: u32,
    index: u32,
) Cancelable!void {
    server.loadPlayerPropertiesFromSave(io, uid, index) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| {
            log.warn("failed to load properties from save for player with uid {d}: {t}", .{ uid, e });

            logic.Properties.setDefaultsAt(
                &server.properties,
                @enumFromInt(index),
            );
        },
    };
}

fn loadPlayerPropertiesFromSave(server: *Server, io: Io, uid: u32, index: u32) !void {
    const arena = server.resettable_arena.allocator();
    defer _ = server.resettable_arena.reset(.retain_capacity);

    const player_save = try server.persistent.loadPlayer(io, arena, uid);

    try logic.Properties.fromPlayerSave(
        &server.properties,
        @enumFromInt(index),
        &player_save,
    );
}

pub fn drainOutgoingQueue(
    server: *Server,
    io: Io,
    current_time: Io.Timestamp,
) Cancelable!void {
    const socket = server.sockets.get(Socket.game.toIndex());

    while (server.multi_conversation.nextUndrained()) |index| try server.drainConversation(
        io,
        socket,
        current_time,
        index,
    );
}

pub fn kick(
    server: *Server,
    io: Io,
    time: Io.Timestamp,
    index: u32,
    reason: rmpb.main.PlayerKickReason,
) void {
    server.savePlayer(io, index);
    defer server.release(index);

    const old_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_cancel_protection);

    if (rmpb.features.isAvailable(.player_kick)) {
        const notify: rmpb.main.PlayerKickScNotify = .{ .reason = reason };

        if (messaging.send(
            &server.multi_conversation,
            &server.clients,
            index,
            .notify,
            notify,
        )) {
            server.drainOutgoingQueue(io, time) catch |err| switch (err) {
                error.Canceled => unreachable, // blocked
            };
        } else |err| switch (err) {
            error.MessageOversize => {},
        }
    }

    var ctl: [kcp.Control.size]u8 = undefined;
    const identifier = server.multi_conversation.identifierAt(index);

    kcp.Control.encode(
        &ctl,
        .disconnect,
        identifier.id,
        identifier.token.downgrade(),
        404,
    );

    const socket = server.sockets.get(Socket.game.toIndex());
    socket.send(io, server.clients.getPtr(.addr, index), &ctl) catch |err| switch (err) {
        error.Canceled => unreachable, // blocked
        else => {},
    };
}

fn drainConversation(
    server: *Server,
    io: Io,
    socket: net.Socket,
    current_time: Io.Timestamp,
    index: u32,
) Cancelable!void {
    server.multi_conversation.updateAt(index, current_time);

    const destination = server.clients.getPtr(.addr, index);
    var output_buf: [kcp.mtu]u8 = undefined;
    var it: kcp.MultiConversation.DrainIterator = .init;

    while (!it.isAtEnd()) {
        const n_send = server.multi_conversation.drainAt(index, &it, &output_buf);
        if (n_send == 0) continue;

        socket.send(io, destination, output_buf[0..n_send]) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => {},
        };
    }
}

const Io = std.Io;
const Random = std.Random;
const Limit = std.Io.Limit;
const Timestamp = std.Io.Timestamp;
const Allocator = std.mem.Allocator;
const Cancelable = std.Io.Cancelable;

const heap = std.heap;
const net = std.Io.net;
const array_hash_map = std.array_hash_map;

const kcp = @import("kcp.zig");
const logic = @import("logic.zig");
const Assets = @import("Assets.zig");
const messaging = @import("messaging.zig");
const Persistent = @import("Persistent.zig");

const rmpb = @import("rmpb");

const std = @import("std");
const Server = @This();
