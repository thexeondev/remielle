const remielle = @import("remielle");
const protobuf = remielle.protobuf;
const pb = protobuf.main;
const pb_stable = protobuf.stable;

const default_interact_target_list: []const pb.InteractTarget = &.{.InteractTarget_NPC};

pub fn switchGameMode(
    assets: *const Assets,
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
        .hall => |*hall| notify.one(.{
            .scene = .{
                .scene_type = 1,
                .hall_scene_data = .{
                    .section_id = @intFromEnum(hall.section_id),
                    .position = switch (hall.position) {
                        .id => null,
                        .transform => |*transform| .{
                            // constCast: read-only access for serialization.
                            .position = .fromOwnedSlice(@constCast(&transform.position)),
                            .rotation = .fromOwnedSlice(@constCast(&transform.rotation)),
                        },
                    },
                    .transform_id = switch (hall.position) {
                        .id => |*id| id.view(),
                        .transform => "",
                    },
                    .scene_time_in_minutes = properties.main_city_time.time_in_minutes,
                    .day_of_week = @intFromEnum(properties.main_city_time.day_of_week),
                    .control_avatar_id = properties.basic_info.control_avatar.toInt(),
                    .control_guise_avatar_id = properties.basic_info.control_guise_avatar.toInt(),
                    .npc_list = npc_list: {
                        const section_index = std.mem.findScalar(
                            u32,
                            main_city.section_ids,
                            @intFromEnum(hall.section_id),
                        ) orelse break :npc_list .empty;

                        var npc_id_list: ArrayList(u32) = .empty;
                        var npc_list: ArrayList(pb.NpcInfo) = .empty;

                        const event = &main_city.events[section_index];

                        for (main_city.actions[event.actions_begin..event.actions_end]) |*action| switch (action.tag) {
                            .create_npc => {
                                const create_npc = action.data.create_npc;
                                const tmpl_index = assets.main_city_object_map.getIndex(create_npc.tag_id) orelse
                                    continue;

                                try npc_id_list.append(notify.allocator, create_npc.tag_id);

                                var npc_info: pb.NpcInfo = .{
                                    .npc_id = create_npc.tag_id,
                                    .is_active = true,
                                };

                                if (templates.main_city_object.default_interact_ids[tmpl_index] != 0) {
                                    const name = templates.main_city_object.interact_names[tmpl_index];

                                    try npc_info.interacts_info.append(notify.allocator, .{
                                        .key = templates.main_city_object.default_interact_ids[tmpl_index],
                                        .value = .{
                                            .tag_id = @intCast(create_npc.tag_id),
                                            .interact_target_list = .fromOwnedSlice(
                                                // constCast: this list won't be modified.
                                                @constCast(default_interact_target_list),
                                            ),
                                            .name = templates.main_city_object.getString(name),
                                            .scale_x = 1,
                                            .scale_y = 1,
                                            .scale_z = 1,
                                            .scale_w = 1,
                                            .scale_r = 1,
                                        },
                                    });
                                }

                                try npc_list.append(notify.allocator, npc_info);
                            },
                            .change_interact => {
                                const change_interact = &main_city.change_interact[action.data.change_interact.toIndex()];
                                const npc_index = std.mem.findScalar(
                                    u32,
                                    npc_id_list.items,
                                    change_interact.tag_id,
                                ) orelse continue;

                                const tmpl_index = assets.main_city_object_map.getIndex(change_interact.tag_id) orelse
                                    continue;

                                const name = templates.main_city_object.interact_names[tmpl_index];

                                // Clobber existing interact, if any.
                                npc_list.items[npc_index].interacts_info.items.len = 0;

                                try npc_list.items[npc_index].interacts_info.append(notify.allocator, .{
                                    .key = change_interact.interact_id,
                                    .value = .{
                                        .tag_id = @intCast(change_interact.tag_id),
                                        .interact_target_list = .fromOwnedSlice(
                                            // constCast: this list won't be modified.
                                            @constCast(default_interact_target_list),
                                        ),
                                        .name = templates.main_city_object.getString(name),
                                        .scale_x = 1,
                                        .scale_y = 1,
                                        .scale_z = 1,
                                        .scale_w = 1,
                                        .scale_r = 1,
                                    },
                                });
                            },
                            .switch_section, .open_ui => unreachable,
                        };

                        break :npc_list npc_list;
                    },
                },
            },
        }),
        .training => |training| notify.one(.{
            .scene = .{
                .scene_type = 3, // training is implemented in terms of FightScene
                .play_type = 290,
                .scene_id = training.quest.getBattleEventId(),
                .fight_scene_data = .{
                    .scene_reward = .init,
                    .scene_perform = .init,
                },
            },
            .dungeon = .{
                .quest_id = @intFromEnum(training.quest),
                .dungeon_package_info = try packers.packDungeonPackageInfo(
                    notify.allocator,
                    &.{training.avatars},
                    &.{}, // buddies
                    properties.avatar,
                    properties.weapon,
                    properties.equip,
                    properties.buddy,
                ),
            },
        }),
        .hadal_zone => |hadal_zone| notify.one(.{
            .scene = .{
                .scene_type = 9,
                .play_type = hadal_zone.getPlayType(),
                .scene_id = hadal_zone.layer.getId(),
                .enemy_property_scale = hadal_zone.getEnemyPropertyScale(),
                .hadal_zone_scene_data = .{
                    .zone_id = @intFromEnum(hadal_zone.layer.zone_id),
                    .room_index = hadal_zone.layer.room_index,
                    .layer_index = hadal_zone.layer.layer_index,
                    .layer_item_id = hadal_zone.layer_item_id,
                    .first_room_avatar_id_list = avatar_id_list: {
                        var list: ArrayList(u32) = try .initCapacity(notify.allocator, 3);
                        for (hadal_zone.rooms.avatar_lists[0]) |slot| if (slot.toId()) |id|
                            list.appendAssumeCapacity(@intFromEnum(id));

                        break :avatar_id_list list;
                    },
                    .second_room_avatar_id_list = avatar_id_list: {
                        var list: ArrayList(u32) = try .initCapacity(notify.allocator, 3);
                        for (hadal_zone.rooms.avatar_lists[1]) |slot| if (slot.toId()) |id|
                            list.appendAssumeCapacity(@intFromEnum(id));

                        break :avatar_id_list list;
                    },
                    .first_room_buddy_id = if (hadal_zone.rooms.buddies[0].toId()) |id|
                        @intFromEnum(id)
                    else
                        0,
                    .second_room_buddy_id = if (hadal_zone.rooms.buddies[1].toId()) |id|
                        @intFromEnum(id)
                    else
                        0,
                },
            },
            .dungeon = dungeon: {
                break :dungeon .{
                    .quest_id = hadal_zone.quest_id,
                    .quest_type = hadal_zone.quest_type,
                    .dungeon_package_info = try packers.packDungeonPackageInfo(
                        notify.allocator,
                        &hadal_zone.rooms.avatar_lists,
                        &hadal_zone.rooms.buddies,
                        properties.avatar,
                        properties.weapon,
                        properties.equip,
                        properties.buddy,
                    ),
                    .avatar_list = avatar_list: {
                        var avatar_list: ArrayList(pb.AvatarUnitInfo) = try .initCapacity(
                            notify.allocator,
                            logic.Changes.GameMode.HadalZone.Rooms.count * logic.Changes.GameMode.AvatarSlot.count,
                        );

                        for (hadal_zone.rooms.avatar_lists) |list| for (list) |slot|
                            if (slot.toId()) |id| {
                                const property_map = try logic.battle.Property.createMap(
                                    notify.allocator,
                                    properties.avatar,
                                    properties.weapon,
                                    properties.equip,
                                    id,
                                );

                                var avatar_unit: pb.AvatarUnitInfo = .{
                                    .avatar_id = @intFromEnum(id),
                                    .properties = try .initCapacity(notify.allocator, property_map.count()),
                                };

                                var iterator = property_map.iterator();
                                while (iterator.next()) |kv|
                                    avatar_unit.properties.appendAssumeCapacity(.{
                                        .key = @intFromEnum(kv.key_ptr.*),
                                        .value = kv.value_ptr.*,
                                    });

                                avatar_list.appendAssumeCapacity(avatar_unit);
                            };

                        break :avatar_list avatar_list;
                    },
                    .buddy_list = buddy_list: {
                        var buddy_list: ArrayList(pb.BuddyUnitInfo) = try .initCapacity(
                            notify.allocator,
                            logic.Changes.GameMode.HadalZone.Rooms.count + 1,
                        );

                        buddy_list.appendAssumeCapacity(.{
                            .buddy_id = templates.buddy_base.assisting_buddy.id,
                            .type = .ASSISTING,
                        });

                        for (hadal_zone.rooms.buddies) |buddy| if (buddy.toId()) |id|
                            buddy_list.appendAssumeCapacity(.{
                                .buddy_id = @intFromEnum(id),
                                .type = .FIGHTING,
                            });

                        break :buddy_list buddy_list;
                    },
                };
            },
        }),
    }
}

pub fn npcInteraction(
    properties: Properties.Immutable(.{
        Properties.Hall,
    }),
    changes: logic.Changes.Subset(.{
        logic.Changes.NpcInteraction,
    }),
    notify: Notify(pb.SectionEventScNotify),
) !void {
    var action_list: ArrayList(pb.ActionInfo) = .empty;

    const interacts = Assets.graphs.interacts;
    const event = &interacts.events[changes.npc_interaction.?.interact_index];

    for (interacts.actions[event.actions_begin..event.actions_end]) |*action| switch (action.tag) {
        .create_npc, .change_interact => {}, // TODO: implement through HallRefreshScNotify

        .switch_section => {
            const switch_section = &interacts.switch_section[action.data.switch_section.toIndex()];

            const info: pb_stable.ActionSwitchSection = .{
                .section_id = switch_section.section_id,
                .transform_id = interacts.getString(switch_section.transform_id),
                .camera_x = switch_section.camera_x,
                .camera_y = switch_section.camera_y,
            };

            try action_list.append(notify.allocator, .{
                .action_type = .ActionType_SWITCH_SECTION,
                .body = try protobuf.encodeAlloc(.stable, notify.allocator, info),
            });
        },

        .open_ui => {
            const open_ui = &interacts.open_ui[action.data.open_ui.toIndex()];

            const info: pb_stable.ActionOpenUi = .{
                .ui = interacts.getString(open_ui.ui),
                .store_template_id = open_ui.store_template_id,
            };

            try action_list.append(notify.allocator, .{
                .action_type = .ActionType_OPEN_UI,
                .body = try protobuf.encodeAlloc(.stable, notify.allocator, info),
            });
        },
    };

    notify.one(.{
        .section_id = @intFromEnum(properties.hall.section_id),
        .action_list = action_list,
    });
}

pub fn hallRefresh(
    properties: Properties.Immutable(.{
        Properties.Hall,
    }),
    changes: logic.Changes.Subset(.{
        logic.Changes.MainCityTime,
    }),
    notify: Notify(pb.HallRefreshScNotify),
) !void {
    notify.one(.{
        .force_refresh = true,
        .section_id = @intFromEnum(properties.hall.section_id),
        .scene_time_in_minutes = changes.main_city_time.?.time_in_minutes,
        .day_of_week = @intFromEnum(changes.main_city_time.?.day_of_week),
    });
}

const templates = Assets.templates;

const Notify = notifiers.Notify;
const ArrayList = std.ArrayList;

const main_city = Assets.graphs.main_city;

const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const packers = @import("../packers.zig");
const notifiers = @import("../notifiers.zig");
const Properties = @import("../../logic/Properties.zig");

const std = @import("std");
