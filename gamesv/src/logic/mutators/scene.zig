pub fn mutateHall(
    changes: logic.Changes.Subset(.{
        logic.Changes.GameMode,
        logic.Changes.PosInMainCity,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.Hall,
    }),
) !void {
    if (changes.game_mode) |game_mode| switch (game_mode.*) {
        .hall => |hall| {
            properties.hall.section_id = hall.section_id;
            properties.hall.position = hall.position;
        },

        .training, .hadal_zone => {},
    };

    if (changes.pos_in_main_city) |pos_in_main_city|
        properties.hall.position = pos_in_main_city.new_position;
}

pub fn mutateMainCityTime(
    changes: logic.Changes.Subset(.{
        logic.Changes.MainCityTime,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.MainCityTime,
    }),
) !void {
    properties.main_city_time.time_in_minutes = changes.main_city_time.?.time_in_minutes;
    properties.main_city_time.day_of_week = changes.main_city_time.?.day_of_week;
}

pub fn mutateHadalZone(
    changes: logic.Changes.Subset(.{
        logic.Changes.GameMode,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.HadalZone,
    }),
) !void {
    if (changes.game_mode) |game_mode| switch (game_mode.*) {
        .hall, .training => {
            properties.hadal_zone.* = .init;
        },
        .hadal_zone => |hadal_zone| {
            properties.hadal_zone.zone_id = @intFromEnum(hadal_zone.layer.zone_id);
            properties.hadal_zone.layer_index = hadal_zone.layer.layer_index;
            properties.hadal_zone.room_index = hadal_zone.layer.room_index;
            properties.hadal_zone.layer_item_id = hadal_zone.layer_item_id;
            for (hadal_zone.rooms.avatar_lists, hadal_zone.rooms.buddies, 0..) |avatar_slots, optional_buddy, room_index| {
                for (avatar_slots[0..logic.Properties.HadalZone.max_avatar_per_room_count], 0..) |avatar_slot, avatar_index| {
                    properties.hadal_zone.avatar_id_list[room_index * logic.Properties.HadalZone.max_avatar_per_room_count + avatar_index] = @intFromEnum(avatar_slot);
                }
                properties.hadal_zone.buddy_id_list[room_index] = @intFromEnum(optional_buddy);
            }
        },
    };
}

pub fn mutateDungeonQuest(
    changes: logic.Changes.Subset(.{
        logic.Changes.GameMode,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.DungeonQuest,
    }),
) !void {
    if (changes.game_mode) |game_mode| switch (game_mode.*) {
        .hall => {
            properties.dungeon_quest.quest_id = 0;
            properties.dungeon_quest.avatar_ids = @splat(0);
        },
        .training => |training| {
            properties.dungeon_quest.quest_id = training.quest.getBattleEventId();
            for (training.avatars, 0..) |avatar, avatar_idx| {
                properties.dungeon_quest.putAvatarId(0, avatar_idx, @intFromEnum(avatar));
            }
        },
        .hadal_zone => |hadal_zone| {
            properties.dungeon_quest.quest_id = hadal_zone.quest_id;
            for (hadal_zone.rooms.avatar_lists, 0..) |room_avatars, room_idx| {
                for (room_avatars, 0..) |avatar, avatar_idx| {
                    properties.dungeon_quest.putAvatarId(room_idx, avatar_idx, @intFromEnum(avatar));
                }
            }
        },
    };
}

const logic = @import("../../logic.zig");
const mutators = @import("../mutators.zig");
