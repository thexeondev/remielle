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
            properties.dungeon_quest.avatar_ids = undefined;
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
