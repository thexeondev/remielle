const std = @import("std");

const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

const packers = @import("../packers.zig");
const logic = @import("../../logic.zig");
const handlers = @import("../handlers.zig");
const Scope = handlers.Scope;

pub fn GetQuestDataCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.GetQuestDataCsReq);

    try scope.sink.respond(pb.GetQuestDataScRsp, .{
        .quest_type = request.quest_type,
        .quest_data = .init,
    });
}

pub fn GetHollowDataCsReq(scope: *Scope) !void {
    try scope.sink.respond(pb.GetHollowDataScRsp, .{
        .hollow_data = .init,
    });
}

pub fn GetArchiveDataCsReq(scope: *Scope) !void {
    try scope.sink.respond(pb.GetArchiveDataScRsp, .{
        .archive_data = .init,
    });
}

pub fn StartTrainingQuestCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.StartTrainingQuestCsReq);

    const quest: templates.training_quest.Id = @fromBackingInt(@intCast(request.quest_id));
    if (quest != .free_training) // Not implemented yet
        return try scope.sink.respond(pb.StartTrainingQuestScRsp, .{ .retcode = 1 });

    switch (request.avatar_id_list.items.len) {
        1...packers.AvatarSlot.count => {},
        else => return try scope.sink.respond(pb.StartTrainingQuestScRsp, .{ .retcode = 1 }),
    }

    var avatars: packers.AvatarSlot.List = undefined;

    for (&avatars, 0..) |*slot, index| {
        if (index >= request.avatar_id_list.items.len) {
            slot.* = .none;
            continue;
        }

        const id = std.enums.fromInt(
            templates.avatar_base.Id,
            request.avatar_id_list.items[index],
        ) orelse
            // invalid avatar id
            return try scope.sink.respond(pb.StartTrainingQuestScRsp, .{ .retcode = 1 });

        if (!scope.properties.avatar.indexes.contains(id))
            // avatar not unlocked
            return try scope.sink.respond(pb.StartTrainingQuestScRsp, .{ .retcode = 1 });

        slot.* = .fromId(id);
    }

    try scope.sink.notify(pb.EnterSceneScNotify, .{
        .scene = .{
            .scene_type = 3, // training is implemented in terms of FightScene
            .play_type = 290,
            .scene_id = quest.getBattleEventId(),
            .fight_scene_data = .{
                .scene_reward = .init,
                .scene_perform = .init,
            },
        },
        .dungeon = try packers.packDungeonInfo(
            scope.sink.allocator,
            @backingInt(quest),
            0,
            &.{avatars},
            &.{},
            &scope.properties.avatar,
            &scope.properties.weapon,
            &scope.properties.equip,
            &scope.properties.buddy,
        ),
    });

    try scope.sink.respond(pb.StartTrainingQuestScRsp, .init);
}

pub fn StartHadalZoneBattleCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.StartHadalZoneBattleCsReq);

    const zone_id = packers.hadal_zone.ZoneId.fromInt(request.zone_id) orelse
        return try scope.sink.respond(pb.StartHadalZoneBattleScRsp, .{ .retcode = 1 });

    const layer: packers.hadal_zone.Layer = .{
        .zone_id = zone_id,
        .layer_index = request.layer_index,
        .room_index = request.room_index,
    };

    const layer_id = layer.getId();

    const quest_id = quest_id: {
        for (templates.hadal_zone_quest.entries) |entry|
            if (entry.layer_id == layer_id)
                break :quest_id entry.quest_id;

        return try scope.sink.respond(pb.StartHadalZoneBattleScRsp, .{ .retcode = 1 });
    };

    const quest_type = quest_type: {
        for (templates.quest_config.entries) |entry|
            if (entry.quest_id == quest_id)
                break :quest_type entry.quest_type;

        return try scope.sink.respond(pb.StartHadalZoneBattleScRsp, .{ .retcode = 1 });
    };

    var avatar_lists: [packers.hadal_zone.room_count]packers.AvatarSlot.List = @splat(@splat(.none));
    var buddies: [packers.hadal_zone.room_count]packers.OptionalBuddy = @splat(.none);

    for (
        &avatar_lists,
        &buddies,
        [_][]const u32{
            request.first_room_avatar_id_list.items,
            request.second_room_avatar_id_list.items,
        },
        [_]u32{
            request.first_room_buddy_id,
            request.second_room_buddy_id,
        },
    ) |*avatar_slots, *optional_buddy, avatar_id_list, raw_buddy_id| {
        for (avatar_slots[0..avatar_id_list.len], avatar_id_list) |*avatar_slot, raw_avatar_id| {
            const avatar_id = std.enums.fromInt(templates.avatar_base.Id, raw_avatar_id) orelse
                // invalid avatar id
                return try scope.sink.respond(pb.StartHadalZoneBattleScRsp, .{ .retcode = 1 });

            if (!scope.properties.avatar.indexes.contains(avatar_id))
                // avatar not unlocked
                return try scope.sink.respond(pb.StartHadalZoneBattleScRsp, .{ .retcode = 1 });

            avatar_slot.* = .fromId(avatar_id);
        }

        if (raw_buddy_id != 0) {
            const buddy_id = std.enums.fromInt(templates.buddy_base.Id, raw_buddy_id) orelse
                // invalid buddy id
                return try scope.sink.respond(pb.StartHadalZoneBattleScRsp, .{ .retcode = 1 });

            if (!scope.properties.buddy.indexes.contains(buddy_id))
                // buddy not unlocked
                return try scope.sink.respond(pb.StartHadalZoneBattleScRsp, .{ .retcode = 1 });

            optional_buddy.* = .fromId(buddy_id);
        }
    }

    try scope.sink.notify(pb.EnterSceneScNotify, .{
        .scene = try packers.packSceneDataForHadalZone(
            scope.sink.allocator,
            &avatar_lists,
            &buddies,
            layer,
            request.layer_item_id,
        ),
        .dungeon = try packers.packDungeonInfo(
            scope.sink.allocator,
            quest_id,
            quest_type,
            &avatar_lists,
            &buddies,
            &scope.properties.avatar,
            &scope.properties.weapon,
            &scope.properties.equip,
            &scope.properties.buddy,
        ),
    });

    try scope.sink.respond(pb.StartHadalZoneBattleScRsp, .init);
}

pub fn EndBattleCsReq(scope: *Scope) !void {
    try scope.sink.respond(pb.EndBattleScRsp, .{ .fight_settle = .init });
}
