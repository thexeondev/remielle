const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const pb_stable = remielle.protobuf.stable;
const protobuf = remielle.protobuf;
const assets = remielle.assets;
const main_city = remielle.assets.graphs.main_city;

pub fn packBuddyInfo(arena: Allocator, id: logic.Properties.Buddy.Id, meta: *const logic.Properties.Buddy.Meta) !pb.BuddyInfo {
    const Buddy = logic.Properties.Buddy;
    var skill_levels: ArrayList(pb.BuddySkillLevel) = try .initCapacity(arena, Buddy.Skill.Levels.len);

    inline for (std.enums.values(Buddy.Skill)) |skill| {
        const level = meta.skill_levels.get(skill);
        skill_levels.appendAssumeCapacity(.{
            .skill_type = skill.toInt(),
            .level = level.toInt(),
        });
    }

    return .{
        .id = @backingInt(id),
        .level = meta.level.toInt(),
        .exp = meta.exp,
        .rank = meta.rank.toInt(),
        .star = meta.star.toInt(),
        .is_favorite = meta.flags.favorite,
        .skill_type_level = skill_levels,
    };
}

pub fn packSelfBasicInfo(arena: Allocator, info: *const Properties.BasicInfo) !pb.SelfBasicInfo {
    _ = arena;

    return .{
        .level = info.level.toInt(),
        .nick_name = "xeondev", // TODO
        .name_change_times = 1, // TODO
        .avatar_id = info.avatar.toInt(),
        .control_avatar_id = info.control_avatar.toInt(),
        .control_guise_avatar_id = info.control_guise_avatar.toInt(),
    };
}

pub fn packAvatarInfo(
    arena: Allocator,
    prop_avatar: *const Properties.Avatar,
    index: usize,
) !pb.AvatarInfo {
    var avatar_skills: [Avatar.Skill.count]pb.AvatarSkillLevel = undefined;

    const meta = &prop_avatar.meta[index];

    for (&avatar_skills, meta.skill_levels, 0..) |*avatar_skill, level, skill_type|
        avatar_skill.* = .{ .skill_type = @intCast(skill_type), .level = level.toInt() };

    var dressed_equip_list: ArrayList(pb.DressedEquip) =
        try .initCapacity(arena, Avatar.equipment_slots);

    for (&prop_avatar.equipment_uids[index], 1..) |maybe_uid, slot| {
        if (maybe_uid.unwrap()) |uid| dressed_equip_list.appendAssumeCapacity(.{
            .index = @intCast(slot),
            .equip_uid = uid,
        });
    }

    return .{
        .id = @backingInt(prop_avatar.ids[index]),
        .level = meta.level.toInt(),
        .rank = meta.rank.toInt(),
        .unlocked_talent_num = meta.talents.toInt(),
        .mindscape_tab_state = .fromOwnedSlice(
            try arena.dupe(bool, &meta.mindscape_tab_state.toBools()),
        ),
        .skill_type_level = .fromOwnedSlice(try arena.dupe(pb.AvatarSkillLevel, &avatar_skills)),
        .passive_skill_level = meta.skill_levels[Avatar.Skill.core_skill.toInt()].toInt() - 1,
        .cur_weapon_uid = prop_avatar.weapon_uids[index].unwrap() orelse 0,
        .dressed_equip_list = dressed_equip_list,
        .is_favorite = meta.flags.favorite,
        .avatar_skin_id = meta.skin.toInt(),
        .awake_id = meta.awakening.toInt(),
        .is_awake_available = meta.flags.awake_available,
        .is_awake_enabled = meta.flags.awake_enabled,
        .show_weapon_type = switch (meta.flags.show_weapon) {
            .locked => .LOCKED,
            .enabled => .SHOW,
            .disabled => .HIDE,
        },
    };
}

pub fn packEquipmentInfo(
    arena: Allocator,
    uid: Equipment.Uid,
    id: u32,
    level: Equipment.Level,
    star: Equipment.Star,
    properties: *const Equipment.Property.List,
) !pb.EquipInfo {
    var equip_properties: ArrayList(pb.EquipProperty) = try .initCapacity(
        arena,
        Properties.Equipment.Property.count,
    );

    equip_properties.appendAssumeCapacity(.{
        .key = @backingInt(properties[0].key), // main property is required.
        .base_value = properties[0].base_value,
        .add_value = properties[0].add_value,
    });

    for (properties[1..]) |prop| if (prop.key.unwrap()) |key|
        equip_properties.appendAssumeCapacity(.{
            .key = key,
            .base_value = prop.base_value,
            .add_value = prop.add_value,
        });

    return .{
        .uid = uid.toInt(),
        .id = id,
        .level = level.toInt(),
        .star = star.toInt(),
        .propertys = .fromOwnedSlice(equip_properties.items[0..1]),
        .sub_propertys = .fromOwnedSlice(equip_properties.items[1..]),
    };
}

pub fn packDungeonPackageInfo(
    arena: Allocator,
    avatar_lists: []const AvatarSlot.List,
    buddies: []const OptionalBuddy,
    avatar: *const Properties.Avatar,
    weapon: *const Properties.Weapon,
    equipment: *const Properties.Equipment,
    buddy: *const Properties.Buddy,
) !pb.DungeonPackageInfo {
    // Always allocates `avatars.len` (which is constant), but that's okay.
    var avatar_list: ArrayList(pb.AvatarInfo) = try .initCapacity(
        arena,
        AvatarSlot.count * avatar_lists.len,
    );

    var weapon_list: ArrayList(pb.WeaponInfo) = try .initCapacity(
        arena,
        AvatarSlot.count * avatar_lists.len,
    );

    var equip_list: ArrayList(pb.EquipInfo) = try .initCapacity(
        arena,
        Properties.Avatar.equipment_slots * AvatarSlot.count * avatar_lists.len,
    );

    var buddy_list: ArrayList(pb.BuddyInfo) = try .initCapacity(
        arena,
        buddies.len,
    );

    for (avatar_lists) |slots| for (slots) |slot| if (slot.toId()) |avatar_id| {
        const index = avatar.indexes.get(avatar_id).?;

        avatar_list.appendAssumeCapacity(try packAvatarInfo(
            arena,
            avatar,
            index,
        ));

        if (avatar.weapon_uids[index].unwrap()) |weapon_uid_int| {
            const weapon_uid = logic.Properties.Weapon.Uid.fromInt(weapon_uid_int).?;
            const weapon_index = std.mem.findScalar(
                logic.Properties.Weapon.Uid,
                &weapon.uids,
                weapon_uid,
            ).?;

            weapon_list.appendAssumeCapacity(.{
                .uid = weapon_uid_int,
                .id = @backingInt(weapon.ids[weapon_index]),
                .level = weapon.levels[weapon_index].toInt(),
                .star = weapon.stars[weapon_index].toInt(),
                .refine_level = weapon.refines[weapon_index].toInt(),
            });
        }

        for (avatar.equipment_uids[index]) |uid| {
            const equip_uid = logic.Properties.Equipment.Uid.fromInt(uid.unwrap() orelse continue).?;
            const equip_index = std.mem.findScalar(
                logic.Properties.Equipment.Uid,
                &equipment.uids,
                equip_uid,
            ).?;

            equip_list.appendAssumeCapacity(try packEquipmentInfo(
                arena,
                equip_uid,
                equipment.ids[equip_index],
                equipment.levels[equip_index],
                equipment.stars[equip_index],
                &equipment.properties[equip_index],
            ));
        }
    };

    for (buddies) |optional_buddy| if (optional_buddy.toId()) |buddy_id| {
        const index = buddy.indexes.get(buddy_id).?;

        buddy_list.appendAssumeCapacity(try packBuddyInfo(
            arena,
            buddy_id,
            &buddy.meta[index],
        ));
    };

    return .{
        .avatar_list = avatar_list,
        .weapon_list = weapon_list,
        .equip_list = equip_list,
    };
}

// TODO: a way to exclude slots.
pub fn packQuickTeamList(
    arena: Allocator,
    quick_teams: []const QuickTeam.Meta,
) !ArrayList(pb.QuickTeam) {
    var list: std.ArrayList(pb.QuickTeam) = try .initCapacity(arena, QuickTeam.slots);

    for (quick_teams, 1..) |*quick_team, slot| {
        var avatar_list: std.ArrayList(pb.QuickTeamAvatar) = try .initCapacity(arena, QuickTeam.avatar_slots);
        for (quick_team.avatar_ids) |avatar_id|
            avatar_list.appendAssumeCapacity(.{ .avatar_id = @backingInt(avatar_id) });

        var buddy_list: std.ArrayList(pb.QuickTeamBuddy) = .empty;
        if (quick_team.buddy_id.unwrap()) |id|
            try buddy_list.append(arena, .{ .buddy_id = id });

        list.appendAssumeCapacity(.{
            .slot = @truncate(slot),
            .name = quick_team.name.view(),
            .avatar_list = avatar_list,
            .buddy_list = buddy_list,
        });
    }

    return list;
}

pub fn packZoneRecord(
    arena: Allocator,
    timestamp: Timestamp,
    entrance_type: pb.EntranceType,
    zone_id: u32,
) !pb.ZoneRecord {
    return .{
        .zone_id = zone_id,
        .begin_timestamp = switch (entrance_type) {
            .NONE, .CONSTANT => 0,
            .SCHEDULED => @intCast(timestamp.toSeconds() - 3600 * 24),
        },
        .end_timestamp = switch (entrance_type) {
            .NONE, .CONSTANT => 0,
            .SCHEDULED => @intCast(timestamp.toSeconds() + 3600 * 24 * 14),
        },
        .layer_record_list = layer_record_list: {
            var list: ArrayList(pb.LayerRecord) = .empty;

            for (assets.templates.zone_info.entries) |zone_info| if (zone_info.zone_id == zone_id) {
                try list.append(arena, .{
                    .layer_index = zone_info.layer_index,
                    .status = @fromBackingInt(@intCast(4)),
                });
            };

            break :layer_record_list list;
        },
    };
}

pub const HallRefreshOptions = struct {
    force: bool,
};

/// Does not pack NPCs.
pub fn packHallRefreshMinimal(
    hall: *const Properties.Hall,
    mct: *const Properties.MainCityTime,
    options: HallRefreshOptions,
) pb.HallRefreshScNotify {
    return .{
        .force_refresh = options.force,
        .section_id = @backingInt(hall.section_id),
        .scene_time_in_minutes = mct.time_in_minutes,
        .day_of_week = @backingInt(mct.day_of_week),
    };
}

pub fn packSectionEventByInteract(
    arena: Allocator,
    hall: *const Properties.Hall,
    interact_index: u32,
) !pb.SectionEventScNotify {
    const interacts = assets.graphs.interacts;
    const event = &interacts.events[interact_index];

    const actions = interacts.actions[event.actions_begin..event.actions_end];
    var action_list: ArrayList(pb.ActionInfo) = try .initCapacity(arena, actions.len);

    for (actions) |*action| switch (action.tag) {
        .create_npc, .change_interact => {},

        .switch_section => {
            const switch_section = &interacts.switch_section[action.data.switch_section.toIndex()];

            const info: pb_stable.ActionSwitchSection = .{
                .section_id = switch_section.section_id,
                .transform_id = interacts.getString(switch_section.transform_id),
                .camera_x = switch_section.camera_x,
                .camera_y = switch_section.camera_y,
            };

            action_list.appendAssumeCapacity(.{
                .action_type = .ActionType_SWITCH_SECTION,
                .body = try protobuf.encodeAlloc(.stable, arena, info),
            });
        },

        .open_ui => {
            const open_ui = &interacts.open_ui[action.data.open_ui.toIndex()];

            const info: pb_stable.ActionOpenUi = .{
                .ui = interacts.getString(open_ui.ui),
                .store_template_id = open_ui.store_template_id,
            };

            action_list.appendAssumeCapacity(.{
                .action_type = .ActionType_OPEN_UI,
                .body = try protobuf.encodeAlloc(.stable, arena, info),
            });
        },
    };

    return .{
        .section_id = @backingInt(hall.section_id),
        .action_list = action_list,
    };
}

const default_interact_target_list: []const pb.InteractTarget = &.{.InteractTarget_NPC};

pub fn packEnterSceneForHall(
    arena: Allocator,
    asset_lookup: *const assets.Lookup,
    hall: *const Properties.Hall,
    mct: *const Properties.MainCityTime,
    /// For control avatar
    basic_info: *const Properties.BasicInfo,
) !pb.EnterSceneScNotify {
    return .{
        .scene = .{
            .scene_type = 1,
            .hall_scene_data = .{
                .section_id = @backingInt(hall.section_id),
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
                .scene_time_in_minutes = mct.time_in_minutes,
                .day_of_week = @backingInt(mct.day_of_week),
                .control_avatar_id = basic_info.control_avatar.toInt(),
                .control_guise_avatar_id = basic_info.control_guise_avatar.toInt(),
                .npc_list = npc_list: {
                    // TODO: audit this hell

                    const section_index = std.mem.findScalar(
                        u32,
                        main_city.section_ids,
                        @backingInt(hall.section_id),
                    ) orelse break :npc_list .empty;

                    var npc_id_list: ArrayList(u32) = .empty;
                    var npc_list: ArrayList(pb.NpcInfo) = .empty;

                    const event = &main_city.events[section_index];

                    for (main_city.actions[event.actions_begin..event.actions_end]) |*action| switch (action.tag) {
                        .create_npc => {
                            const create_npc = action.data.create_npc;
                            const tmpl_index = asset_lookup.main_city_object_map.getIndex(create_npc.tag_id) orelse
                                continue;

                            try npc_id_list.append(arena, create_npc.tag_id);

                            var npc_info: pb.NpcInfo = .{
                                .npc_id = create_npc.tag_id,
                                .is_active = true,
                            };

                            if (assets.templates.main_city_object.default_interact_ids[tmpl_index] != 0) {
                                const name = assets.templates.main_city_object.interact_names[tmpl_index];

                                try npc_info.interacts_info.append(arena, .{
                                    .key = assets.templates.main_city_object.default_interact_ids[tmpl_index],
                                    .value = .{
                                        .tag_id = @intCast(create_npc.tag_id),
                                        .interact_target_list = .fromOwnedSlice(
                                            // constCast: this list won't be modified.
                                            @constCast(default_interact_target_list),
                                        ),
                                        .name = assets.templates.main_city_object.getString(name),
                                        .scale_x = 1,
                                        .scale_y = 1,
                                        .scale_z = 1,
                                        .scale_w = 1,
                                        .scale_r = 1,
                                    },
                                });
                            }

                            try npc_list.append(arena, npc_info);
                        },
                        .change_interact => {
                            const change_interact = &main_city.change_interact[action.data.change_interact.toIndex()];
                            const npc_index = std.mem.findScalar(
                                u32,
                                npc_id_list.items,
                                change_interact.tag_id,
                            ) orelse continue;

                            const tmpl_index = asset_lookup.main_city_object_map.getIndex(change_interact.tag_id) orelse
                                continue;

                            const name = assets.templates.main_city_object.interact_names[tmpl_index];

                            // Clobber existing interact, if any.
                            npc_list.items[npc_index].interacts_info.items.len = 0;

                            try npc_list.items[npc_index].interacts_info.append(arena, .{
                                .key = change_interact.interact_id,
                                .value = .{
                                    .tag_id = @intCast(change_interact.tag_id),
                                    .interact_target_list = .fromOwnedSlice(
                                        // constCast: this list won't be modified.
                                        @constCast(default_interact_target_list),
                                    ),
                                    .name = assets.templates.main_city_object.getString(name),
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
    };
}

// TODO: perhaps `packers` is not the best place for this.
pub const AvatarSlot = enum(u32) {
    pub const count = 3;
    pub const List = [count]AvatarSlot;

    none = 0,
    _,

    pub inline fn fromId(id: assets.templates.avatar_base.Id) AvatarSlot {
        return @fromBackingInt(@intCast(@backingInt(id)));
    }

    pub inline fn toId(slot: AvatarSlot) ?assets.templates.avatar_base.Id {
        return switch (slot) {
            .none => null,
            else => |id| @fromBackingInt(@intCast(@backingInt(id))),
        };
    }
};

// TODO: perhaps `packers` is not the best place for this (x2).
pub const OptionalBuddy = enum(u32) {
    none = 0,
    _,

    pub inline fn fromId(id: assets.templates.buddy_base.Id) OptionalBuddy {
        return @fromBackingInt(@intCast(@backingInt(id)));
    }

    pub inline fn toId(optional: OptionalBuddy) ?assets.templates.buddy_base.Id {
        return switch (optional) {
            .none => null,
            else => |id| @fromBackingInt(@intCast(@backingInt(id))),
        };
    }
};

// TODO: perhaps `packers` is not the best place for this (x3).
pub const hadal_zone = struct {
    pub const room_count = 2;

    pub const Layer = struct {
        zone_id: ZoneId,
        room_index: u32,
        layer_index: u32,

        pub fn getId(layer: *const Layer) u32 {
            return switch (Group.fromZoneId(layer.zone_id)) {
                .scheduled => switch (layer.room_index) {
                    0 => ZoneId.scheduled.toInt() * 100 + layer.layer_index,
                    else => ZoneId.impact.toInt() * 100 + layer.layer_index * 10 + layer.room_index,
                },
                .boss_challenge => ZoneId.boss_challenge.toInt() * 100 + layer.layer_index,
                .stable => @backingInt(layer.zone_id) * 100 + layer.layer_index,
                .free_training => 6900404,
            };
        }
    };

    pub const ZoneId = enum(u32) {
        scheduled = 62001,
        alive_count = 61002,
        impact = 62010,
        boss_challenge = 69001,
        free_training = 89001,
        _,

        pub fn fromInt(int: u32) ?ZoneId {
            if (Group.fromZoneIdInt(int) == null)
                return null;

            return @fromBackingInt(@intCast(int));
        }

        pub inline fn toInt(id: ZoneId) u32 {
            return @backingInt(id);
        }
    };

    const Group = enum(u32) {
        stable = 61,
        scheduled = 62,
        boss_challenge = 69,
        free_training = 89,

        pub fn fromZoneId(id: ZoneId) Group {
            return fromZoneIdInt(@backingInt(id)).?;
        }

        pub fn fromZoneIdInt(int: u32) ?Group {
            var group_num = int;
            while ((group_num / 100) > 0) group_num /= 10;

            return std.enums.fromInt(Group, group_num);
        }
    };
};

pub fn packSceneDataForHadalZone(
    arena: Allocator,
    avatar_lists: *const [hadal_zone.room_count]AvatarSlot.List,
    buddies: *const [hadal_zone.room_count]OptionalBuddy,
    layer: hadal_zone.Layer,
    layer_item_id: u32,
) !pb.SceneData {
    const play_type: u32 = switch (layer.zone_id) {
        .alive_count => 222, // HADAL_ZONE_ALIVECOUNT
        else => |zone_id| switch (hadal_zone.Group.fromZoneId(zone_id)) {
            .boss_challenge, .free_training => 224, // HADAL_ZONE_BOSSCHALLENGE
            .stable, .scheduled => switch (layer.room_index) {
                0 => 209, // HADAL_ZONE
                else => 303, // HADAL_ZONE_IMPACT_BATTLE
            },
        },
    };

    return .{
        .scene_type = 9,
        .play_type = play_type,
        .scene_id = layer.getId(),
        .enemy_property_scale = switch (play_type) {
            224 => 33,
            303 => 61,
            else => 19,
        },
        .hadal_zone_scene_data = .{
            .zone_id = @backingInt(layer.zone_id),
            .room_index = layer.room_index,
            .layer_index = layer.layer_index,
            .layer_item_id = layer_item_id,
            .first_room_avatar_id_list = avatar_id_list: {
                var list: ArrayList(u32) = try .initCapacity(arena, 3);
                for (avatar_lists[0]) |slot| if (slot.toId()) |id|
                    list.appendAssumeCapacity(@backingInt(id));

                break :avatar_id_list list;
            },
            .second_room_avatar_id_list = avatar_id_list: {
                var list: ArrayList(u32) = try .initCapacity(arena, 3);
                for (avatar_lists[1]) |slot| if (slot.toId()) |id|
                    list.appendAssumeCapacity(@backingInt(id));

                break :avatar_id_list list;
            },
            .first_room_buddy_id = if (buddies[0].toId()) |id|
                @backingInt(id)
            else
                0,
            .second_room_buddy_id = if (buddies[1].toId()) |id|
                @backingInt(id)
            else
                0,
        },
    };
}

pub fn packDungeonInfo(
    arena: Allocator,
    quest_id: u32,
    quest_type: u32,
    avatar_lists: []const AvatarSlot.List,
    buddies: []const OptionalBuddy,
    avatar: *const Properties.Avatar,
    weapon: *const Properties.Weapon,
    equipment: *const Properties.Equipment,
    buddy: *const Properties.Buddy,
) !pb.DungeonInfo {
    return .{
        .quest_id = quest_id,
        .quest_type = quest_type,
        .dungeon_package_info = try packDungeonPackageInfo(
            arena,
            avatar_lists,
            buddies,
            avatar,
            weapon,
            equipment,
            buddy,
        ),
        .avatar_list = avatar_list: {
            var avatar_list: ArrayList(pb.AvatarUnitInfo) = try .initCapacity(
                arena,
                avatar_lists.len * AvatarSlot.count,
            );

            for (avatar_lists) |list| for (list) |slot|
                if (slot.toId()) |id| {
                    const property_map = try logic.battle.Property.createMap(
                        arena,
                        avatar,
                        weapon,
                        equipment,
                        id,
                    );

                    var avatar_unit: pb.AvatarUnitInfo = .{
                        .avatar_id = @backingInt(id),
                        .properties = try .initCapacity(arena, property_map.count()),
                    };

                    var iterator = property_map.iterator();
                    while (iterator.next()) |kv|
                        avatar_unit.properties.appendAssumeCapacity(.{
                            .key = @backingInt(kv.key_ptr.*),
                            .value = kv.value_ptr.*,
                        });

                    avatar_list.appendAssumeCapacity(avatar_unit);
                };

            break :avatar_list avatar_list;
        },
        .buddy_list = buddy_list: {
            var buddy_list: ArrayList(pb.BuddyUnitInfo) = try .initCapacity(
                arena,
                buddies.len + 1,
            );

            buddy_list.appendAssumeCapacity(.{
                .buddy_id = assets.templates.buddy_base.assisting_buddy.id,
                .type = .ASSISTING,
            });

            for (buddies) |buddy_entry| if (buddy_entry.toId()) |id|
                buddy_list.appendAssumeCapacity(.{
                    .buddy_id = @backingInt(id),
                    .type = .FIGHTING,
                });

            break :buddy_list buddy_list;
        },
    };
}

const Timestamp = std.Io.Timestamp;
const ArrayList = std.ArrayList;
const Avatar = Properties.Avatar;
const Equipment = Properties.Equipment;
const QuickTeam = Properties.QuickTeam;
const Properties = logic.Properties;
const Allocator = std.mem.Allocator;

const logic = @import("../logic.zig");

const std = @import("std");
