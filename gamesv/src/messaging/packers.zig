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
    id: Avatar.Id,
    meta: *const Avatar.Meta,
    weapon_uid: Avatar.OptionalUID,
    equipment_uids: [Avatar.equipment_slots]Avatar.OptionalUID,
) !pb.AvatarInfo {
    var avatar_skills: [Avatar.Skill.count]pb.AvatarSkillLevel = undefined;

    for (&avatar_skills, meta.skill_levels, 0..) |*avatar_skill, level, skill_type|
        avatar_skill.* = .{ .skill_type = @intCast(skill_type), .level = level.toInt() };

    var dressed_equip_list: ArrayList(pb.DressedEquip) = try .initCapacity(arena, Avatar.equipment_slots);

    for (equipment_uids, 1..) |maybe_uid, slot| if (maybe_uid.unwrap()) |uid|
        dressed_equip_list.appendAssumeCapacity(.{
            .index = @intCast(slot),
            .equip_uid = uid,
        });

    return .{
        .id = @backingInt(id),
        .level = meta.level.toInt(),
        .rank = meta.rank.toInt(),
        .unlocked_talent_num = meta.talents.toInt(),
        .mindscape_tab_state = .fromOwnedSlice(try arena.dupe(bool, &meta.mindscape_tab_state.toBools())),
        .skill_type_level = .fromOwnedSlice(try arena.dupe(pb.AvatarSkillLevel, &avatar_skills)),
        .passive_skill_level = meta.skill_levels[Avatar.Skill.core_skill.toInt()].toInt() - 1,
        .cur_weapon_uid = weapon_uid.unwrap() orelse 0,
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
    buddies: []const GameMode.OptionalBuddy,
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
            avatar_id,
            &avatar.meta[index],
            avatar.weapon_uids[index],
            avatar.equipment_uids[index],
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

pub fn packQuickTeamData(arena: Allocator, quick_teams: []const QuickTeam.Meta) !pb.QuickTeamData {
    var quick_team_list: std.ArrayList(pb.QuickTeam) = try .initCapacity(arena, QuickTeam.slots);

    for (quick_teams, 1..) |*quick_team, slot| {
        var avatar_list: std.ArrayList(pb.QuickTeamAvatar) = try .initCapacity(arena, QuickTeam.avatar_slots);
        for (quick_team.avatar_ids) |avatar_id| avatar_list.appendAssumeCapacity(.{ .avatar_id = @backingInt(avatar_id) });

        var buddy_list: std.ArrayList(pb.QuickTeamBuddy) = .empty;
        if (quick_team.buddy_id.unwrap()) |id| try buddy_list.append(arena, .{ .buddy_id = id });

        quick_team_list.appendAssumeCapacity(.{
            .slot = @truncate(slot),
            .name = quick_team.name.view(),
            .avatar_list = avatar_list,
            .buddy_list = buddy_list,
        });
    }

    return .{ .quick_team_list = quick_team_list };
}

pub fn packQuickTeamSync(arena: Allocator, quick_teams: []const logic.Changes.QuickTeam) !pb.QuickTeamSync {
    var quick_team_list: std.ArrayList(pb.QuickTeam) = try .initCapacity(arena, quick_teams.len);

    for (quick_teams) |*quick_team| {
        var avatar_list: std.ArrayList(pb.QuickTeamAvatar) = try .initCapacity(arena, QuickTeam.avatar_slots);
        for (quick_team.meta.avatar_ids) |avatar_id| avatar_list.appendAssumeCapacity(.{ .avatar_id = @backingInt(avatar_id) });

        var buddy_list: std.ArrayList(pb.QuickTeamBuddy) = .empty;
        if (quick_team.meta.buddy_id.unwrap()) |id| try buddy_list.append(arena, .{ .buddy_id = id });

        quick_team_list.appendAssumeCapacity(.{
            .slot = @backingInt(quick_team.slot),
            .name = quick_team.meta.name.view(),
            .avatar_list = avatar_list,
            .buddy_list = buddy_list,
        });
    }

    return .{ .quick_team_list = quick_team_list };
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

pub fn packDungeonInfo(
    arena: Allocator,
    quest_id: u32,
    quest_type: u32,
    avatar_lists: []const AvatarSlot.List,
    buddies: []const GameMode.OptionalBuddy,
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
const GameMode = logic.Changes.GameMode;
const Avatar = Properties.Avatar;
const Equipment = Properties.Equipment;
const QuickTeam = Properties.QuickTeam;
const Properties = logic.Properties;
const Allocator = std.mem.Allocator;

const logic = @import("../logic.zig");

const std = @import("std");
