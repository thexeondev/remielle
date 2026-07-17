const remielle = @import("remielle");
const protobuf = remielle.protobuf;
const templates = remielle.assets.templates;

pub fn playerKick(
    operation: control.Operation(remielle.control.Operation.PlayerKick),
    context: *const control.Context,
) !void {
    try context.sendEvent(remielle.control.Event.Ack, .{});

    const server = context.server;

    const index: u32 = @intCast(server.uid_map.getIndex(operation.data.uid) orelse return);

    const reason: protobuf.main.PlayerKickReason = std.enums.fromInt(
        protobuf.main.PlayerKickReason,
        operation.data.reason,
    ) orelse @enumFromInt(0);

    server.kick(context.io, context.time, index, reason);
}

pub fn modAvatarMeta(
    operation: control.Operation(remielle.control.Operation.ModAvatarMeta),
    context: *const control.Context,
) !void {
    const server = context.server;

    const player_index: u32 = @intCast(server.uid_map.getIndex(operation.data.player_uid) orelse {
        // TODO: offline changes.
        return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .no_entry, .extra = 0 });
    });

    const avatar_id = std.enums.fromInt(templates.avatar_base.Id, operation.data.avatar_id) orelse
        return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

    const avatar = server.properties.getPtr(.avatar, player_index);

    const index = avatar.indexes.get(avatar_id) orelse
        return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

    const value = operation.data.value;
    var meta = avatar.meta[index];

    switch (operation.data.field) {
        _ => return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 }),
        .level => {
            if (value > Avatar.Level.max.toInt() or value < Avatar.Level.init.toInt())
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            meta.level = @enumFromInt(@as(u8, @intCast(value)));
        },
        .exp => {
            meta.exp = std.math.cast(u32, value) orelse
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });
        },
        .rank => {
            if (value > Avatar.Rank.max.toInt() or value < Avatar.Rank.init.toInt())
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            meta.rank = @enumFromInt(@as(u8, @intCast(value)));
        },
        .talents => {
            if (value > Avatar.Talents.max.toInt() or value < Avatar.Talents.init.toInt())
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            meta.talents = @enumFromInt(@as(u8, @intCast(value)));
        },
        .mindscape_tab_state => {
            const mind = Avatar.MindscapeTabState.fromBits(@truncate(value)) orelse
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            meta.mindscape_tab_state = mind;
        },
        .skill_level => {
            const encoded: remielle.control.Operation.ModAvatarMeta.Skill = @bitCast(value);
            const skill = std.enums.fromInt(Avatar.Skill, encoded.skill) orelse
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            if (encoded.level < Avatar.Skill.Level.init.toInt() or
                encoded.level > Avatar.Skill.Level.maxFor(skill).toInt())
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            meta.skill_levels[skill.toInt()] = @enumFromInt(@as(u8, @intCast(encoded.level)));
        },
        .skin => {
            const skin_id = std.enums.fromInt(templates.avatar_skin_base.Id, value) orelse
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            meta.skin = @enumFromInt(@intFromEnum(skin_id));
        },
        .awakening => {
            meta.awakening = @enumFromInt(@as(u32, @intCast(value)));
        },
        .favorite => {
            meta.flags.favorite = value != 0;
        },
        .show_weapon => {
            meta.flags.show_weapon = std.enums.fromInt(Avatar.Flags.ShowWeapon, value) orelse
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });
        },
    }

    var changes: logic.Changes = .init;
    const change: logic.Changes.Avatar = .{
        .id = avatar.ids[index],
        .meta = meta,
        .weapon_uid = avatar.weapon_uids[index],
        .equipment_uids = avatar.equipment_uids[index],
        .awake_material_count = avatar.awake_material_counts[index],
    };

    changes.avatars = (&change)[0..1];

    const frame: Server.Frame = .{
        .target_index = player_index,
        .time = context.time,
        .clients = &server.clients,
        .asset_lookup = server.asset_lookup,
        .properties = &server.properties,
        .calendar = &server.persistent.calendar,
        .multi_conversation = &server.multi_conversation,
    };

    try logic.mutators.dispatchLogicChanges(&frame, &changes);
    try messaging.notifiers.notifyLogicChanges(server.resettable_arena.allocator(), &frame, &changes);

    try context.sendEvent(remielle.control.Event.Ack, .{});
}

pub fn createWeapon(
    extended: control.ExtendedOperation(remielle.control.Operation.CreateWeapon),
    context: *const control.Context,
) !void {
    const server = context.server;

    const player_index: u32 = @intCast(server.uid_map.getIndex(extended.operation.player_uid) orelse {
        // TODO: offline changes.
        return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .no_entry, .extra = 0 });
    });

    const weapon = server.properties.getPtr(.weapon, player_index);

    if (weapon.count + extended.entries.len > Weapon.capacity)
        return context.sendEvent(remielle.control.Event.Nak, .{
            .reason = .no_space_left,
            .extra = Weapon.capacity - weapon.count,
        });

    const arena = server.resettable_arena.allocator();

    var changes: logic.Changes = .init;
    const weapons = try arena.alloc(logic.Changes.Weapon, extended.entries.len);

    for (weapons, extended.entries, 0..) |*change, *entry, i|
        change.* = .{
            .uid = @enumFromInt(@as(u16, @intCast(weapon.count + i))),
            .id = std.enums.fromInt(Weapon.Id, entry.id) orelse
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 }),
            .level = Weapon.Level.fromInt(entry.meta.level) orelse
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 }),
            .star = Weapon.Star.fromInt(entry.meta.star) orelse
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 }),
            .refine = Weapon.Refine.fromInt(entry.meta.refine) orelse
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 }),
        };

    changes.weapons = weapons;

    const frame: Server.Frame = .{
        .target_index = player_index,
        .time = context.time,
        .clients = &server.clients,
        .asset_lookup = server.asset_lookup,
        .properties = &server.properties,
        .calendar = &server.persistent.calendar,
        .multi_conversation = &server.multi_conversation,
    };

    try logic.mutators.dispatchLogicChanges(&frame, &changes);
    try messaging.notifiers.notifyLogicChanges(arena, &frame, &changes);

    try context.sendEvent(remielle.control.Event.Ack, .{});
}

pub fn createEquip(
    extended: control.ExtendedOperation(remielle.control.Operation.CreateEquip),
    context: *const control.Context,
) !void {
    const server = context.server;

    const player_index: u32 = @intCast(server.uid_map.getIndex(extended.operation.player_uid) orelse {
        // TODO: offline changes.
        return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .no_entry, .extra = 0 });
    });

    const equip = server.properties.getPtr(.equip, player_index);

    if (equip.count + extended.entries.len > Equipment.capacity)
        return context.sendEvent(remielle.control.Event.Nak, .{
            .reason = .no_space_left,
            .extra = Equipment.capacity - equip.count,
        });

    const arena = server.resettable_arena.allocator();

    var changes: logic.Changes = .init;
    const equipment = try arena.alloc(logic.Changes.Equip, extended.entries.len);

    for (equipment, extended.entries, 0..) |*change, *entry, i| {
        for (templates.equipment.entries) |template| {
            if (template.item_id == entry.id) break;
        } else return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

        change.* = .{
            .uid = @enumFromInt(@as(u16, @intCast(equip.count + i))),
            .id = entry.id,
            .level = Equipment.Level.fromInt(entry.meta.level) orelse
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 }),
            .star = Equipment.Star.fromInt(entry.meta.star) orelse
                return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 }),
            .properties = properties: {
                var properties: Equipment.Property.List = undefined;
                for (&properties, &entry.properties) |*property, *input|
                    property.* = .{
                        .key = @enumFromInt(input.key),
                        .base_value = input.base_value,
                        .add_value = input.add_value,
                    };

                break :properties properties;
            },
        };
    }

    changes.equipment = equipment;

    const frame: Server.Frame = .{
        .target_index = player_index,
        .time = context.time,
        .clients = &server.clients,
        .asset_lookup = server.asset_lookup,
        .properties = &server.properties,
        .calendar = &server.persistent.calendar,
        .multi_conversation = &server.multi_conversation,
    };

    try logic.mutators.dispatchLogicChanges(&frame, &changes);
    try messaging.notifiers.notifyLogicChanges(arena, &frame, &changes);

    try context.sendEvent(remielle.control.Event.Ack, .{});
}

const Avatar = logic.Properties.Avatar;
const Weapon = logic.Properties.Weapon;
const Equipment = logic.Properties.Equipment;

const app = @import("../app.zig");
const logic = @import("../logic.zig");
const Server = @import("../Server.zig");
const control = @import("../control.zig");
const messaging = @import("../messaging.zig");

const std = @import("std");
