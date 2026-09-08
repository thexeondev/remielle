const std = @import("std");
const ArrayList = std.ArrayList;

const remielle = @import("remielle");
const protobuf = remielle.protobuf;
const pb = protobuf.main;
const pb_stable = protobuf.stable;
const assets = remielle.assets;
const templates = assets.templates;
const main_city = assets.graphs.main_city;

const notifiers = @import("../notifiers.zig");
const Notify = notifiers.Notify;

const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const Properties = @import("../../logic/Properties.zig");

pub fn switchGameMode(
    properties: logic.Properties.Immutable(.{
        logic.Properties.BasicInfo,
        logic.Properties.Avatar,
        logic.Properties.Buddy,
        logic.Properties.Weapon,
        logic.Properties.Equipment,
        logic.Properties.MainCityTime,
    }),
    changes: logic.Changes.Subset(.{
        logic.Changes.GameMode,
    }),
    notify: Notify(pb.EnterSceneScNotify),
) !void {
    const game_mode = changes.game_mode.?;

    switch (game_mode.*) {
        .hadal_zone => |hadal_zone| notify.one(.{
            .scene = .{
                .scene_type = 9,
                .play_type = hadal_zone.getPlayType(),
                .scene_id = hadal_zone.layer.getId(),
                .enemy_property_scale = hadal_zone.getEnemyPropertyScale(),
                .hadal_zone_scene_data = .{
                    .zone_id = @backingInt(hadal_zone.layer.zone_id),
                    .room_index = hadal_zone.layer.room_index,
                    .layer_index = hadal_zone.layer.layer_index,
                    .layer_item_id = hadal_zone.layer_item_id,
                    .first_room_avatar_id_list = avatar_id_list: {
                        var list: ArrayList(u32) = try .initCapacity(notify.allocator, 3);
                        for (hadal_zone.rooms.avatar_lists[0]) |slot| if (slot.toId()) |id|
                            list.appendAssumeCapacity(@backingInt(id));

                        break :avatar_id_list list;
                    },
                    .second_room_avatar_id_list = avatar_id_list: {
                        var list: ArrayList(u32) = try .initCapacity(notify.allocator, 3);
                        for (hadal_zone.rooms.avatar_lists[1]) |slot| if (slot.toId()) |id|
                            list.appendAssumeCapacity(@backingInt(id));

                        break :avatar_id_list list;
                    },
                    .first_room_buddy_id = if (hadal_zone.rooms.buddies[0].toId()) |id|
                        @backingInt(id)
                    else
                        0,
                    .second_room_buddy_id = if (hadal_zone.rooms.buddies[1].toId()) |id|
                        @backingInt(id)
                    else
                        0,
                },
            },
            .dungeon = try packers.packDungeonInfo(
                notify.allocator,
                hadal_zone.quest_id,
                hadal_zone.quest_type,
                &hadal_zone.rooms.avatar_lists,
                &hadal_zone.rooms.buddies,
                properties.avatar,
                properties.weapon,
                properties.equip,
                properties.buddy,
            ),
        }),
    }
}
