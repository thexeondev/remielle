pub const std_options: std.Options = .{
    .logFn = rmio.log.logFn,
};

const mtu = 1200;

const loopback: net.IpAddress = .{ .ip4 = .loopback(0) };
const default_destination = net.IpAddress.parseLiteral("127.0.0.1:15810") catch unreachable;

const destination_envvar = "REMIELLE_GAMESV_ADDRESS";

const CommandTag = enum {
    @"kick-player",
};

pub fn main(init: Init) void {
    const io = init.io;

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err|
        fatal("failed to collect command line arguments: {t}", .{err});

    const command: cli.Command = .parse(args[1..]);

    const destination = if (init.environ_map.get(destination_envvar)) |literal|
        net.IpAddress.parseLiteral(literal) catch
            fatal("'" ++ destination_envvar ++ "' contains an invalid address", .{})
    else
        default_destination;

    const socket = loopback.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch |err|
        fatal("bind: {t}", .{err});

    defer socket.close(io);

    var recv_buffer: [mtu]u8 align(@alignOf(u64)) = undefined;

    var random_impl: std.Random.IoSource = .{ .io = io };
    const random = random_impl.interface();

    const userdata = random.int(u32);

    switch (command) {
        .@"kick-player" => |kick_player| {
            const kick_message: Operation.Message(Operation.PlayerKick) = .init(userdata, .{
                .uid = kick_player.uid,
                .reason = kick_player.reason,
            });

            socket.send(io, &destination, @ptrCast(&kick_message)) catch |err|
                fatal("send: {t}", .{err});

            const ack = receive(rmnet.Event.Ack, io, &socket, &recv_buffer);
            _ = ack;
        },
        .@"mod-avatar-meta" => |mod_avatar_meta| {
            const value: u64 = switch (mod_avatar_meta.field) {
                _ => unreachable,
                .skill_level => skill_level: {
                    const skill: Operation.ModAvatarMeta.Skill = .{
                        .skill = mod_avatar_meta.value,
                        .level = mod_avatar_meta.value_extra,
                    };

                    break :skill_level @bitCast(skill);
                },
                inline else => mod_avatar_meta.value,
            };

            const mod_message: Operation.Message(Operation.ModAvatarMeta) = .init(userdata, .{
                .player_uid = mod_avatar_meta.uid,
                .avatar_id = mod_avatar_meta.id,
                .field = mod_avatar_meta.field,
                .value = value,
            });

            socket.send(io, &destination, @ptrCast(&mod_message)) catch |err|
                fatal("send: {t}", .{err});

            const ack = receive(rmnet.Event.Ack, io, &socket, &recv_buffer);
            _ = ack;
        },
        .@"create-weapon" => |create_weapon| {
            var creation_message: Operation.ExtendedMessageBuffer(Operation.CreateWeapon, 1) = .init(.init(
                userdata,
                .{
                    .player_uid = create_weapon.player_uid,
                    .count = 0, // Initial value must be zero. Will be incremented by appendAssumeCapacity.
                },
            ));

            creation_message.appendAssumeCapacity(.{
                .id = create_weapon.item_id,
                .meta = .{
                    .level = create_weapon.level,
                    .star = create_weapon.star,
                    .refine = create_weapon.refine,
                    .reserved = 0,
                },
            });

            socket.send(io, &destination, creation_message.payload()) catch |err|
                fatal("send: {t}", .{err});

            const ack = receive(rmnet.Event.Ack, io, &socket, &recv_buffer);
            _ = ack;
        },
        .@"create-equip" => |create_equip| {
            var creation_message: Operation.ExtendedMessageBuffer(Operation.CreateEquip, 1) = .init(.init(
                userdata,
                .{
                    .player_uid = create_equip.player_uid,
                    .count = 0, // Initial value must be zero. Will be incremented by appendAssumeCapacity.
                },
            ));

            var properties: [5]Operation.CreateEquip.Entry.Property = undefined;

            inline for (&properties, 0..) |*property, i| {
                const index: u8 = @intCast(i);
                property.* = .{
                    .key = @field(create_equip, "property_key_" ++ .{'0' + index}),
                    .base_value = @field(create_equip, "property_base_value_" ++ .{'0' + index}),
                    .add_value = @field(create_equip, "property_add_value_" ++ .{'0' + index}),
                };
            }

            creation_message.appendAssumeCapacity(.{
                .id = create_equip.item_id,
                .properties = properties,
                .meta = .{
                    .level = create_equip.level,
                    .star = create_equip.star,
                    .reserved = 0,
                },
            });

            socket.send(io, &destination, creation_message.payload()) catch |err|
                fatal("send: {t}", .{err});

            const ack = receive(rmnet.Event.Ack, io, &socket, &recv_buffer);
            _ = ack;
        },
        .@"random-equip" => |random_equip| {
            const batch_size = 40;

            var batch_message: Operation.ExtendedMessageBuffer(Operation.CreateEquip, batch_size) = .init(.init(
                userdata,
                .{
                    .player_uid = random_equip.player_uid,
                    .count = 0,
                },
            ));

            const time: Io.Timestamp = .now(io, .awake);
            var rng_impl: std.Random.DefaultPrng = .init(@bitCast(time.toSeconds()));
            const rng = rng_impl.random();

            var amount = random_equip.amount;
            while (amount != 0) : (amount -= 1) {
                const slot = (rng.int(u8) % 6) + 1;
                const suit_index = rng.int(usize) % equipment_suit.entries.len;
                const suit_id = equipment_suit.entries[suit_index].id;
                const equip_id = suit_id + 40 + slot;

                var properties: [5]Operation.CreateEquip.Entry.Property = undefined;
                rand_properties.fill(rng, slot, &properties);

                batch_message.appendAssumeCapacity(.{
                    .id = @intCast(equip_id),
                    .properties = properties,
                    .meta = .{
                        .level = 15,
                        .star = 5,
                        .reserved = 0,
                    },
                });

                if (amount == 1 or batch_message.base.operation.count == batch_size) {
                    socket.send(io, &destination, batch_message.payload()) catch |err|
                        fatal("send: {t}", .{err});

                    const ack = receive(rmnet.Event.Ack, io, &socket, &recv_buffer);
                    _ = ack;

                    batch_message.base.operation.count = 0;
                }
            }
        },
    }
}

fn receive(
    comptime ExpectedEvent: type,
    io: Io,
    socket: *const net.Socket,
    buf: *align(@alignOf(u64)) [mtu]u8,
) *const ExpectedEvent {
    const udp_message = socket.receive(io, buf) catch |err|
        fatal("receive failed: {t}", .{err});

    const data = buf[0..udp_message.data.len];

    if (data.len < @sizeOf(rmnet.ServerHeader))
        fatal("invalid packet received from the server", .{});

    const header: *rmnet.ServerHeader = @ptrCast(data[0..@sizeOf(rmnet.ServerHeader)]);

    if (header.protocol_version != rmnet.Version.current)
        fatal("server protocol version did not match: {d}", .{header.protocol_version});

    switch (header.event_tag) {
        ExpectedEvent.tag => {
            if (header.event_version != ExpectedEvent.version)
                fatal("server {t} event version doesn't match: {d}", .{ header.event_tag, header.event_version });

            const ExpectedMessage = rmnet.Event.Message(ExpectedEvent);

            if (data.len != @sizeOf(ExpectedMessage))
                fatal(
                    "received malformed message from server (expected size: {d}, received: {d})",
                    .{ @sizeOf(ExpectedMessage), data.len },
                );

            const message: *ExpectedMessage = @ptrCast(data);

            return &message.event;
        },
        .nak => {
            if (header.event_version != rmnet.Event.Nak.version)
                fatal("server {t} event version doesn't match: {d}", .{ header.event_tag, header.event_version });

            const NakMessage = rmnet.Event.Message(rmnet.Event.Nak);

            if (data.len != @sizeOf(NakMessage))
                fatal("received negative acknowledgement from server", .{});

            const nak_message: *NakMessage = @ptrCast(data);

            switch (nak_message.event.reason) {
                _ => fatal("received negative acknowledgement from server", .{}),
                else => |reason| fatal("error: {t} ({d})", .{ reason, nak_message.event.extra }),
            }
        },
        _ => |unknown| fatal("received unknown event, tag: {d}", .{@intFromEnum(unknown)}),
        // else => |unexpected| fatal("received unexpected event ({t})", .{unexpected}),
    }
}

const fatal = std.process.fatal;

const Operation = rmnet.Operation;

const Io = std.Io;
const Init = std.process.Init;

const net = std.Io.net;

const cli = @import("cli.zig");
const equipment_suit = @import("equipment_suit.zig");
const rand_properties = @import("rand_properties.zig");

const rmio = @import("rmio");
const rmnet = @import("rmnet");

const builtin = @import("builtin");
const std = @import("std");
