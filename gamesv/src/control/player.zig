pub fn playerKick(
    operation: control.Operation(rmnet.Operation.PlayerKick),
    context: *const control.Context,
) !void {
    try context.sendEvent(rmnet.Event.Ack, .{});

    const server = context.server;

    const index: u32 = @intCast(server.uid_map.getIndex(operation.data.uid) orelse return);

    const reason: rmpb.main.PlayerKickReason = std.enums.fromInt(
        rmpb.main.PlayerKickReason,
        operation.data.reason,
    ) orelse @enumFromInt(0);

    const socket = context.sockets.get(app.SocketKind.game.toIndex());
    server.kick(context.io, context.time, socket, index, reason);
}

pub fn modAvatarMeta(
    operation: control.Operation(rmnet.Operation.ModAvatarMeta),
    context: *const control.Context,
) !void {
    const server = context.server;

    const player_index: u32 = @intCast(server.uid_map.getIndex(operation.data.player_uid) orelse {
        // TODO: offline changes.
        return context.sendEvent(rmnet.Event.Nak, .{ .reason = .no_entry, .extra = 0 });
    });

    const avatar_id = std.enums.fromInt(templates.avatar_base.Id, operation.data.avatar_id) orelse
        return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

    const avatar = server.properties.getPtr(.avatar, player_index);

    const index = avatar.indexes.get(avatar_id) orelse
        return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

    const value = operation.data.value;
    var meta = avatar.meta[index];

    switch (operation.data.field) {
        _ => return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 }),
        .level => {
            if (value > Avatar.Level.max.toInt() or value < Avatar.Level.init.toInt())
                return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            meta.level = @enumFromInt(@as(u8, @intCast(value)));
        },
        .exp => {
            meta.exp = std.math.cast(u32, value) orelse
                return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });
        },
        .rank => {
            if (value > Avatar.Rank.max.toInt() or value < Avatar.Rank.init.toInt())
                return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            meta.rank = @enumFromInt(@as(u8, @intCast(value)));
        },
        .talents => {
            if (value > Avatar.Talents.max.toInt() or value < Avatar.Talents.init.toInt())
                return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            meta.talents = @enumFromInt(@as(u8, @intCast(value)));
        },
        .mindscape_tab_state => {
            const mind = Avatar.MindscapeTabState.fromBits(@truncate(value)) orelse
                return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            meta.mindscape_tab_state = mind;
        },
        .skill_level => {
            const encoded: rmnet.Operation.ModAvatarMeta.Skill = @bitCast(value);
            const skill = std.enums.fromInt(Avatar.Skill, encoded.skill) orelse
                return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            if (encoded.level < Avatar.Skill.Level.init.toInt() or
                encoded.level > Avatar.Skill.Level.maxFor(skill).toInt())
                return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

            meta.skill_levels[skill.toInt()] = @enumFromInt(@as(u8, @intCast(encoded.level)));
        },
        .skin => {
            const skin_id = std.enums.fromInt(templates.avatar_skin_base.Id, value) orelse
                return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

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
                return context.sendEvent(rmnet.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });
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
        .assets = server.assets,
        .properties = &server.properties,
        .multi_conversation = &server.multi_conversation,
    };

    try logic.mutators.dispatchLogicChanges(&frame, &changes);
    try messaging.notifiers.notifyLogicChanges(server.resettable_arena.allocator(), &frame, &changes);

    try context.sendEvent(rmnet.Event.Ack, .{});
}

const Avatar = logic.Properties.Avatar;

const templates = Assets.templates;

const app = @import("../app.zig");
const logic = @import("../logic.zig");
const Server = @import("../Server.zig");
const Assets = @import("../Assets.zig");
const control = @import("../control.zig");
const messaging = @import("../messaging.zig");

const rmpb = @import("rmpb");
const rmnet = @import("rmnet");

const std = @import("std");
