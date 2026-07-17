const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

pub fn getQuestData(
    message: Message(pb.GetQuestDataCsReq),
    response: Response(pb.GetQuestDataScRsp),
) !void {
    response.set(.{
        .quest_type = message.data.quest_type,
        .quest_data = .init,
    });
}

pub fn getHollowData(
    message: Message(pb.GetHollowDataCsReq),
    response: Response(pb.GetHollowDataScRsp),
) !void {
    _ = message;
    response.set(.{ .hollow_data = .init });
}

pub fn getArchiveData(
    message: Message(pb.GetArchiveDataCsReq),
    response: Response(pb.GetArchiveDataScRsp),
) !void {
    _ = message;
    response.set(.{ .archive_data = .init });
}

pub fn startTrainingQuest(
    message: Message(pb.StartTrainingQuestCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.GameMode,
    }),
    response: Response(pb.StartTrainingQuestScRsp),
) !void {
    const quest: templates.training_quest.Id = @enumFromInt(message.data.quest_id);
    if (quest != .free_training) // Not implemented yet
        return response.fail(1);

    switch (message.data.avatar_id_list.items.len) {
        1...Changes.GameMode.AvatarSlot.count => {},
        else => return response.fail(1),
    }

    var avatars: Changes.GameMode.AvatarSlot.List = undefined;

    for (&avatars, 0..) |*slot, index| {
        if (index >= message.data.avatar_id_list.items.len) {
            slot.* = .none;
            continue;
        }

        const id = std.enums.fromInt(
            templates.avatar_base.Id,
            message.data.avatar_id_list.items[index],
        ) orelse
            return response.fail(1); // invalid avatar id

        if (!properties.avatar.indexes.contains(id))
            return response.fail(1); // avatar not unlocked

        slot.* = .fromId(id);
    }

    const mode_switch: Changes.GameMode = .{ .training = .{
        .quest = quest,
        .avatars = avatars,
    } };

    changes.insert(mode_switch);
    response.set(.init);
}

pub fn startHadalZoneBattle(
    message: Message(pb.StartHadalZoneBattleCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
        Properties.Buddy,
    }),
    changes: Changes.Builder(.{
        Changes.GameMode,
    }),
    response: Response(pb.StartHadalZoneBattleScRsp),
) !void {
    const zone_id = Changes.GameMode.HadalZone.ZoneId.fromInt(message.data.zone_id) orelse
        return response.fail(1);

    const layer: Changes.GameMode.HadalZone.Layer = .{
        .zone_id = zone_id,
        .layer_index = message.data.layer_index,
        .room_index = message.data.room_index,
    };

    const layer_id = layer.getId();

    const quest_id = quest_id: {
        for (templates.hadal_zone_quest.entries) |entry|
            if (entry.layer_id == layer_id)
                break :quest_id entry.quest_id;

        return response.fail(1);
    };

    const quest_type = quest_type: {
        for (templates.quest_config.entries) |entry|
            if (entry.quest_id == quest_id)
                break :quest_type entry.quest_type;

        return response.fail(1);
    };

    var rooms: Changes.GameMode.HadalZone.Rooms = .empty;

    for (
        &rooms.avatar_lists,
        &rooms.buddies,
        [_][]const u32{ message.data.first_room_avatar_id_list.items, message.data.second_room_avatar_id_list.items },
        [_]u32{ message.data.first_room_buddy_id, message.data.second_room_buddy_id },
    ) |*avatar_slots, *optional_buddy, avatar_id_list, raw_buddy_id| {
        for (avatar_slots[0..avatar_id_list.len], avatar_id_list) |*avatar_slot, raw_avatar_id| {
            const avatar_id = std.enums.fromInt(templates.avatar_base.Id, raw_avatar_id) orelse
                return response.fail(1); // invalid avatar id

            if (!properties.avatar.indexes.contains(avatar_id))
                return response.fail(1); // avatar not unlocked

            avatar_slot.* = .fromId(avatar_id);
        }

        if (raw_buddy_id != 0) {
            const buddy_id = std.enums.fromInt(templates.buddy_base.Id, raw_buddy_id) orelse
                return response.fail(1); // invalid buddy id

            if (!properties.buddy.indexes.contains(buddy_id))
                return response.fail(1);

            optional_buddy.* = .fromId(buddy_id);
        }
    }

    const mode_switch: Changes.GameMode = .{ .hadal_zone = .{
        .rooms = rooms,
        .layer = layer,
        .layer_item_id = message.data.layer_item_id,
        .quest_id = quest_id,
        .quest_type = quest_type,
    } };

    changes.insert(mode_switch);
    response.set(.init);
}

pub fn endBattle(
    message: Message(pb.EndBattleCsReq),
    response: Response(pb.EndBattleScRsp),
) !void {
    _ = message;
    response.set(.{ .fight_settle = .init });
}

const Changes = logic.Changes;
const Message = handlers.Message;
const Response = handlers.Response;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const handlers = @import("../handlers.zig");

const std = @import("std");
