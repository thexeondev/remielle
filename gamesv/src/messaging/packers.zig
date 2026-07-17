const remielle = @import("remielle");
const pb = remielle.protobuf.main;

pub fn packBuddyInfo(arena: Allocator, id: logic.Properties.Buddy.Id, meta: *const logic.Properties.Buddy.Meta) !pb.BuddyInfo {
    const Buddy = logic.Properties.Buddy;
    var skill_levels: ArrayList(pb.BuddySkillLevel) = try .initCapacity(arena, Buddy.Skill.Levels.len);

    inline for (std.meta.fields(Buddy.Skill)) |field| {
        const skill: Buddy.Skill = @enumFromInt(field.value);
        const level = meta.skill_levels.get(skill);
        skill_levels.appendAssumeCapacity(.{
            .skill_type = skill.toInt(),
            .level = level.toInt(),
        });
    }

    return .{
        .id = @intFromEnum(id),
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
        .id = @intFromEnum(id),
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
        .key = @intFromEnum(properties[0].key), // main property is required.
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
    avatar_lists: []const GameMode.AvatarSlot.List,
    buddies: []const GameMode.OptionalBuddy,
    avatar: *const Properties.Avatar,
    weapon: *const Properties.Weapon,
    equipment: *const Properties.Equipment,
    buddy: *const Properties.Buddy,
) !pb.DungeonPackageInfo {
    // Always allocates `avatars.len` (which is constant), but that's okay.
    var avatar_list: ArrayList(pb.AvatarInfo) = try .initCapacity(
        arena,
        GameMode.AvatarSlot.count * avatar_lists.len,
    );

    var weapon_list: ArrayList(pb.WeaponInfo) = try .initCapacity(
        arena,
        GameMode.AvatarSlot.count * avatar_lists.len,
    );

    var equip_list: ArrayList(pb.EquipInfo) = try .initCapacity(
        arena,
        Properties.Avatar.equipment_slots * GameMode.AvatarSlot.count * avatar_lists.len,
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
                .id = @intFromEnum(weapon.ids[weapon_index]),
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
        for (quick_team.avatar_ids) |avatar_id| avatar_list.appendAssumeCapacity(.{ .avatar_id = @intFromEnum(avatar_id) });

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
        for (quick_team.meta.avatar_ids) |avatar_id| avatar_list.appendAssumeCapacity(.{ .avatar_id = @intFromEnum(avatar_id) });

        var buddy_list: std.ArrayList(pb.QuickTeamBuddy) = .empty;
        if (quick_team.meta.buddy_id.unwrap()) |id| try buddy_list.append(arena, .{ .buddy_id = id });

        quick_team_list.appendAssumeCapacity(.{
            .slot = @intFromEnum(quick_team.slot),
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

            for (Assets.templates.zone_info.entries) |zone_info| if (zone_info.zone_id == zone_id) {
                try list.append(arena, .{
                    .layer_index = zone_info.layer_index,
                    .status = @enumFromInt(4),
                });
            };

            break :layer_record_list list;
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
const Assets = @import("../Assets.zig");

const std = @import("std");
