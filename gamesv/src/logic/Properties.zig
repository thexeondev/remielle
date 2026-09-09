const Properties = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const remielle = @import("remielle");
const mem = remielle.mem;
const pb = remielle.protobuf.stable;
const templates = remielle.assets.templates;

pub const Avatar = @import("Properties/Avatar.zig");
pub const PlayerAccessory = @import("Properties/PlayerAccessory.zig");
pub const Buddy = @import("Properties/Buddy.zig");
pub const Weapon = @import("Properties/Weapon.zig");
pub const Equipment = @import("Properties/Equipment.zig");
pub const Hall = @import("Properties/Hall.zig");
pub const QuickTeam = @import("Properties/QuickTeam.zig");

basic_info: BasicInfo,
player_accessory: PlayerAccessory,
avatar: Avatar,
buddy: Buddy,
weapon: Weapon,
equip: Equipment,
hall: Hall,
main_city_time: MainCityTime,
quick_team: QuickTeam,

pub const init: Properties = .{
    .basic_info = .init,
    .player_accessory = .init,
    .avatar = .init,
    .buddy = .init,
    .weapon = .init,
    .equip = .init,
    .hall = .init,
    .main_city_time = .init,
    .quick_team = .init,
};

pub fn setDefaults(props: *Properties) void {
    props.unlockAllAvatars();
    props.unlockAllBuddies();
    props.unlockAllWeapons();
}

fn unlockAllAvatars(properties: *Properties) void {
    const avatar = &properties.avatar;

    for (templates.avatar_base.entries) |template| if (template.camp != 0) if (template.id < 2_000) {
        const i = avatar.indexes.count();
        avatar.indexes.put(template.getId(), @intCast(i));
        avatar.ids[i] = template.getId();

        avatar.meta[i] = .{
            .level = .max,
            .exp = 0,
            .rank = .max,
            .talents = .max,
            .mindscape_tab_state = .init,
            .flags = .init,
            .skill_levels = undefined,
            .skin = .none,
            .awakening = .none,
        };

        inline for (&avatar.meta[i].skill_levels, 0..) |*level, skill_type|
            level.* = .maxFor(@fromBackingInt(@intCast(skill_type)));

        avatar.weapon_uids[i] = .none;
        avatar.equipment_uids[i] = @splat(.none);
        avatar.awake_material_counts[i] = .none;
    };

    for (templates.avatar_special_awaken.entries) |template| {
        const maybe_index: ?u32 = avatar_index: {
            const id = std.enums.fromInt(Properties.Avatar.Id, template.avatar_id) orelse
                break :avatar_index null;

            break :avatar_index avatar.indexes.get(id);
        };

        const index = maybe_index orelse continue;

        avatar.awake_material_counts[index] = .add(avatar.awake_material_counts[index], 1);
    }
}

fn unlockAllBuddies(properties: *Properties) void {
    const buddy = &properties.buddy;

    for (templates.buddy_base.entries) |template| if (template.id < 55000) {
        const i = buddy.indexes.count();
        buddy.indexes.put(template.getId(), @intCast(i));
        buddy.ids[i] = template.getId();

        buddy.meta[i] = .{
            .level = .max,
            .exp = 0,
            .rank = .max,
            .star = .init,
            .skill_levels = .initUndefined(),
            .flags = .init,
        };

        inline for (std.enums.values(Properties.Buddy.Skill)) |skill|
            buddy.meta[i].skill_levels.set(skill, .maxFor(skill));
    };
}

fn unlockAllWeapons(properties: *Properties) void {
    const weapon = &properties.weapon;

    for (templates.weapon.entries) |template| {
        defer weapon.count += 1;
        const i = weapon.count;

        weapon.uids[i] = @fromBackingInt(@intCast(i));
        weapon.ids[i] = template.getId();
        weapon.levels[i] = .max;
        weapon.stars[i] = .max;
        weapon.refines[i] = .max;
    }
}

pub const MainCityTime = struct {
    time_in_minutes: u11,
    day_of_week: DayOfWeek,

    pub const init: MainCityTime = .{
        .time_in_minutes = TimePeriod.toTimeInMinutes(.morning),
        .day_of_week = .friday,
    };

    pub const TimePeriod = enum(u11) {
        morning = 1,
        afternoon = 2,
        evening = 3,
        night = 4,

        pub inline fn toTimeInMinutes(time_period: TimePeriod) u11 {
            return @mod(@backingInt(time_period) * 360, 1440);
        }

        pub inline fn fromTimeInMinutes(time_in_minutes: u11) TimePeriod {
            const t = @mod(time_in_minutes, 1440) / 360;
            return @fromBackingInt(@intCast(if (t == 0) 4 else t));
        }

        pub inline fn isNextDayOf(next: TimePeriod, prev: TimePeriod) bool {
            return @backingInt(prev) > @backingInt(next);
        }
    };

    pub const DayOfWeek = enum(u3) {
        sunday,
        monday,
        tuesday,
        wednesday,
        thursday,
        friday,
        saturday,

        pub inline fn nextDay(day: DayOfWeek) DayOfWeek {
            return @fromBackingInt(@intCast(@mod(@backingInt(day) + 1, 7)));
        }
    };
};

pub const BasicInfo = struct {
    level: Level,
    avatar: HallAvatar,
    control_avatar: HallAvatar,
    control_guise_avatar: HallAvatar.Guise,
    control_guise_avatar_skin: HallAvatar.Guise.Skin,

    pub const init: BasicInfo = .{
        .level = .max,
        .avatar = .wise,
        .control_avatar = .wise,
        .control_guise_avatar = .fromIdUnchecked(.remielle),
        .control_guise_avatar_skin = .none,
    };
};

pub const Level = enum(u8) {
    init = templates.yorozuya_level.entries[0].level,
    max = templates.yorozuya_level.entries[templates.yorozuya_level.entries.len - 1].level,
    _,

    pub fn toInt(level: Level) u32 {
        return @backingInt(level);
    }
};

pub const HallAvatar = enum(u32) {
    none = 0,
    wise = @backingInt(templates.avatar_base.Id.wise),
    belle = @backingInt(templates.avatar_base.Id.belle),

    /// Doesn't allow zero.
    pub fn fromInt(int: u32) ?HallAvatar {
        const avatar = std.enums.fromInt(HallAvatar, int) orelse
            return null;

        return switch (avatar) {
            .wise, .belle => |a| a,
            .none => null,
        };
    }

    pub fn toInt(avatar: HallAvatar) u32 {
        return @backingInt(avatar);
    }

    pub const Guise = enum(u32) {
        none = 0,
        wise = @backingInt(HallAvatar.wise),
        belle = @backingInt(HallAvatar.belle),
        _,

        pub const Skin = Properties.Avatar.Skin;

        pub const FromRawIdError = error{
            InvalidAvatarId,
            AvatarNotUnlocked,
        };

        pub fn fromRawId(player_avatar_prop: *const Avatar, raw_id: u32) !Guise {
            if (raw_id == 0) return .none;

            const id = std.enums.fromInt(templates.avatar_base.Id, raw_id) orelse
                return error.InvalidAvatarId;

            return switch (id) {
                .wise, .belle => .fromIdUnchecked(id),
                else => if (player_avatar_prop.indexes.contains(id))
                    .fromIdUnchecked(id)
                else
                    error.AvatarNotUnlocked,
            };
        }

        pub fn getSkin(guise: Guise, player_avatar_prop: *const Avatar, player_accessory_prop: *const PlayerAccessory) Skin {
            return switch (guise) {
                .none => .none,
                .wise, .belle => player_accessory_prop.meta.get(.fromGuiseUnchecked(guise)).skin,
                _ => |guise_avatar_id| guise_avatar_id: {
                    const index = player_avatar_prop.indexes.get(@fromBackingInt(@intCast(guise_avatar_id.toInt()))).?;
                    break :guise_avatar_id player_avatar_prop.meta[index].skin;
                },
            };
        }

        pub fn fromIdUnchecked(id: templates.avatar_base.Id) Guise {
            return @fromBackingInt(@intCast(@backingInt(id)));
        }

        pub fn toInt(guise: Guise) u32 {
            return @backingInt(guise);
        }
    };
};

pub fn toPlayerSave(properties: *Properties, arena: Allocator) Allocator.Error!pb.PlayerSave {
    const basic_info = &properties.basic_info;
    const basic_save: pb.BasicSave = .{
        .level = basic_info.level.toInt(),
        .avatar_id = basic_info.avatar.toInt(),
        .control_avatar_id = basic_info.control_avatar.toInt(),
        .control_guise_avatar_id = basic_info.control_guise_avatar.toInt(),
        .control_guise_avatar_skin_id = basic_info.control_guise_avatar_skin.toInt(),
    };

    const player_accessory = &properties.player_accessory;

    var player_accessory_save: pb.PlayerAccessorySave = .init;
    try player_accessory_save.avatars.ensureTotalCapacity(arena, PlayerAccessory.slots);

    inline for (std.enums.values(PlayerAccessory.Avatar)) |avatar|
        player_accessory_save.avatars.appendAssumeCapacity(.{
            .id = @backingInt(avatar),
            .skin_id = @backingInt(player_accessory.meta.get(avatar).skin),
        });

    const avatar = &properties.avatar;
    const avatar_count = avatar.indexes.count();

    var avatar_save: pb.AvatarSave = .init;
    try avatar_save.items.ensureTotalCapacity(arena, avatar_count);

    for (
        avatar.ids[0..avatar_count],
        avatar.meta[0..avatar_count],
        avatar.weapon_uids[0..avatar_count],
        avatar.equipment_uids[0..avatar_count],
        avatar.awake_material_counts[0..avatar_count],
    ) |id, *meta, weapon_uid, *equipment_uids, awake_material_count| {
        var skill_levels: std.ArrayList(u32) = try .initCapacity(arena, Avatar.Skill.count);

        for (meta.skill_levels) |level|
            skill_levels.appendAssumeCapacity(level.toInt());

        avatar_save.items.appendAssumeCapacity(.{
            .id = @backingInt(id),
            .level = meta.level.toInt(),
            .exp = meta.exp,
            .rank = meta.rank.toInt(),
            .talents = meta.talents.toInt(),
            .mindscape_tab_state = @backingInt(meta.mindscape_tab_state),
            .favorite = meta.flags.favorite,
            .skill_levels = skill_levels,
            .skin_id = meta.skin.toInt(),
            .awake_available = meta.flags.awake_available,
            .awake_enabled = meta.flags.awake_enabled,
            .awake_id = meta.awakening.toInt(),
            .show_weapon = @backingInt(meta.flags.show_weapon),
            .weapon_uid = @backingInt(weapon_uid),
            .equipment_uids = .fromOwnedSlice(try arena.dupe(u32, @ptrCast(equipment_uids))),
            .awake_material_count = awake_material_count.toInt(),
        });
    }

    const buddy = &properties.buddy;
    const buddy_count = buddy.indexes.count();

    var buddy_save: pb.BuddySave = .init;
    try buddy_save.items.ensureTotalCapacity(arena, buddy_count);

    for (buddy.ids[0..buddy_count], buddy.meta[0..buddy_count]) |id, *meta| {
        var skill_levels: std.ArrayList(u32) = try .initCapacity(arena, Properties.Buddy.Skill.Levels.len);

        inline for (std.enums.values(Properties.Buddy.Skill)) |skill|
            skill_levels.appendAssumeCapacity(meta.skill_levels.get(skill).toInt());

        buddy_save.items.appendAssumeCapacity(.{
            .id = @backingInt(id),
            .level = meta.level.toInt(),
            .exp = meta.exp,
            .rank = meta.rank.toInt(),
            .star = meta.star.toInt(),
            .favorite = meta.flags.favorite,
            .skill_levels = skill_levels,
        });
    }

    const weapon = &properties.weapon;
    var weapon_save: pb.WeaponSave = .init;
    try weapon_save.items.ensureTotalCapacity(arena, weapon.count);

    for (
        weapon.uids[0..weapon.count],
        weapon.ids[0..weapon.count],
        weapon.levels[0..weapon.count],
        weapon.stars[0..weapon.count],
        weapon.refines[0..weapon.count],
    ) |uid, id, level, star, refine| {
        weapon_save.items.appendAssumeCapacity(.{
            .id = @backingInt(id),
            .uid = @backingInt(uid),
            .level = level.toInt(),
            .star = star.toInt(),
            .refine = refine.toInt(),
        });
    }

    const equip: *Equipment = &properties.equip;
    var equip_save: pb.EquipSave = .init;
    try equip_save.items.ensureTotalCapacity(arena, equip.count);

    for (
        equip.uids[0..equip.count],
        equip.ids[0..equip.count],
        equip.levels[0..equip.count],
        equip.stars[0..equip.count],
        equip.properties[0..equip.count],
    ) |uid, id, level, star, *property_list| {
        var equip_properties: std.ArrayList(pb.EquipProperty) = try .initCapacity(
            arena,
            Equipment.Property.count,
        );

        for (property_list) |*prop| equip_properties.appendAssumeCapacity(.{
            .key = @backingInt(prop.key),
            .base_value = prop.base_value,
            .add_value = prop.add_value,
        });

        equip_save.items.appendAssumeCapacity(.{
            .uid = @backingInt(uid),
            .id = id,
            .level = level.toInt(),
            .star = star.toInt(),
            .properties = equip_properties,
        });
    }

    const hall = &properties.hall;
    const hall_save: pb.HallSave = .{
        .section_id = @backingInt(hall.section_id),
        .position_id = switch (hall.position) {
            .id => |*id| id.view(),
            .transform => "",
        },
        .position_transform = switch (hall.position) {
            .id => null,
            .transform => |*transform| .{
                .position = .fromOwnedSlice(&transform.position),
                .rotation = .fromOwnedSlice(&transform.rotation),
            },
        },
    };

    const main_city_time = &properties.main_city_time;
    const main_city_time_save: pb.MainCityTimeSave = .{
        .time_in_minutes = main_city_time.time_in_minutes,
        .day_of_week = @backingInt(main_city_time.day_of_week),
    };

    const quick_team = &properties.quick_team;
    var quick_team_save: pb.QuickTeamSave = .{
        .teams = try .initCapacity(arena, QuickTeam.slots),
    };

    for (&quick_team.meta) |*meta| {
        const team = quick_team_save.teams.addOneAssumeCapacity();

        team.* = .{
            .name = meta.name.view(),
            .avatar_ids = try .initCapacity(arena, Properties.QuickTeam.avatar_slots),
            .buddy_id = @backingInt(meta.buddy_id),
        };

        for (meta.avatar_ids) |avatar_id|
            team.avatar_ids.appendAssumeCapacity(@backingInt(avatar_id));
    }

    return .{
        .basic = basic_save,
        .player_accessory = player_accessory_save,
        .avatar = avatar_save,
        .buddy = buddy_save,
        .weapon = weapon_save,
        .equip = equip_save,
        .hall = hall_save,
        .main_city_time = main_city_time_save,
        .quick_team = quick_team_save,
    };
}

pub fn fromPlayerSave(
    properties: *Properties,
    save: *const pb.PlayerSave,
) !void {
    properties.basic_info = if (save.basic) |basic| .{
        .level = @fromBackingInt(@intCast(basic.level)),
        .avatar = @fromBackingInt(@intCast(basic.avatar_id)),
        .control_avatar = @fromBackingInt(@intCast(basic.control_avatar_id)),
        .control_guise_avatar = @fromBackingInt(@intCast(basic.control_guise_avatar_id)),
        .control_guise_avatar_skin = @fromBackingInt(@intCast(basic.control_guise_avatar_skin_id)),
    } else .init;

    const player_accessory = &properties.player_accessory;
    player_accessory.* = .init;

    if (save.player_accessory) |player_accessory_save|
        for (player_accessory_save.avatars.items) |avatar|
            player_accessory.meta.set(@fromBackingInt(@intCast(avatar.id)), .{ .skin = @fromBackingInt(@intCast(avatar.skin_id)) });

    if (save.avatar) |avatar_save| {
        const avatar = &properties.avatar;
        avatar.* = .init;

        for (avatar_save.items.items, 0..) |*item, i| {
            avatar.indexes.put(@fromBackingInt(@intCast(item.id)), @intCast(i));
            avatar.ids[i] = @fromBackingInt(@intCast(item.id));

            avatar.meta[i] = .{
                .level = @fromBackingInt(@intCast(item.level)),
                .exp = item.exp,
                .rank = @fromBackingInt(@intCast(item.rank)),
                .talents = @fromBackingInt(@intCast(item.talents)),
                .mindscape_tab_state = @fromBackingInt(@intCast(item.mindscape_tab_state)),
                .flags = .{
                    .favorite = item.favorite,
                    .awake_available = item.awake_available,
                    .awake_enabled = item.awake_enabled,
                    .show_weapon = @fromBackingInt(@intCast(item.show_weapon)),
                },
                .skill_levels = undefined,
                .skin = @fromBackingInt(@intCast(item.skin_id)),
                .awakening = @fromBackingInt(@intCast(item.awake_id)),
            };

            inline for (&avatar.meta[i].skill_levels, 0..) |*level, skill_i|
                level.* = if (item.skill_levels.items.len > skill_i)
                    @fromBackingInt(@intCast(item.skill_levels.items[skill_i]))
                else
                    .maxFor(@fromBackingInt(@intCast(skill_i)));

            avatar.weapon_uids[i] = @fromBackingInt(@intCast(item.weapon_uid));

            for (&avatar.equipment_uids[i], 0..) |*equipment_uid, slot_i|
                equipment_uid.* = if (item.equipment_uids.items.len > slot_i)
                    @fromBackingInt(@intCast(item.equipment_uids.items[slot_i]))
                else
                    .none;

            avatar.awake_material_counts[i] = @fromBackingInt(@intCast(item.awake_material_count));
        }
    } else {
        properties.avatar = .init;
        properties.unlockAllAvatars();
    }

    if (save.buddy) |buddy_save| {
        const buddy = &properties.buddy;
        buddy.* = .init;

        for (buddy_save.items.items, 0..) |*item, i| {
            buddy.indexes.put(@fromBackingInt(@intCast(item.id)), @intCast(i));
            buddy.ids[i] = @fromBackingInt(@intCast(item.id));

            buddy.meta[i] = .{
                .level = @fromBackingInt(@intCast(item.level)),
                .exp = item.exp,
                .rank = @fromBackingInt(@intCast(item.rank)),
                .star = @fromBackingInt(@intCast(item.star)),
                .skill_levels = .initUndefined(),
                .flags = .{
                    .favorite = item.favorite,
                },
            };

            inline for (std.enums.values(Properties.Buddy.Skill), 0..) |skill, skill_i| {
                buddy.meta[i].skill_levels.set(skill, if (item.skill_levels.items.len > skill_i)
                    @fromBackingInt(@intCast(item.skill_levels.items[skill_i]))
                else
                    .maxFor(skill));
            }
        }
    } else {
        properties.buddy = .init;
        properties.unlockAllBuddies();
    }

    if (save.weapon) |weapon_save| {
        const weapon = &properties.weapon;
        weapon.* = .init;

        weapon.count = @intCast(weapon_save.items.items.len);

        for (weapon_save.items.items, 0..) |*item, i| {
            weapon.uids[i] = @fromBackingInt(@intCast(item.uid));
            weapon.ids[i] = @fromBackingInt(@intCast(item.id));
            weapon.levels[i] = @fromBackingInt(@intCast(item.level));
            weapon.stars[i] = @fromBackingInt(@intCast(item.star));
            weapon.refines[i] = @fromBackingInt(@intCast(item.refine));
        }
    } else {
        properties.weapon = .init;
        properties.unlockAllWeapons();
    }

    if (save.equip) |equip_save| {
        const equip = &properties.equip;
        equip.* = .init;

        equip.count = @intCast(equip_save.items.items.len);

        for (equip_save.items.items, 0..) |*item, i| {
            equip.uids[i] = @fromBackingInt(@intCast(item.uid));
            equip.ids[i] = item.id;
            equip.levels[i] = @fromBackingInt(@intCast(item.level));
            equip.stars[i] = @fromBackingInt(@intCast(item.star));
            equip.properties[i] = @splat(.none);

            const prop_count = @min(item.properties.items.len, Equipment.Property.count);

            for (item.properties.items[0..prop_count], equip.properties[i][0..prop_count]) |saved, *property|
                property.* = .{
                    .key = @fromBackingInt(@intCast(saved.key)),
                    .base_value = @truncate(saved.base_value),
                    .add_value = @truncate(saved.add_value),
                };
        }
    } else {
        properties.equip = .init;
    }

    properties.hall = if (save.hall) |hall_save| .{
        .section_id = @fromBackingInt(@intCast(hall_save.section_id)),
        .position = (if (hall_save.position_transform) |transform|
            Hall.Position.fromVectors(
                transform.position.items,
                transform.rotation.items,
            )
        else
            Hall.Position.fromId(hall_save.position_id)) orelse .init,
    } else .init;

    properties.main_city_time = if (save.main_city_time) |main_city_time_save| .{
        .time_in_minutes = @truncate(main_city_time_save.time_in_minutes),
        .day_of_week = @fromBackingInt(@intCast(main_city_time_save.day_of_week)),
    } else .init;

    if (save.quick_team) |quick_team_save| {
        const quick_team = &properties.quick_team;

        for (quick_team_save.teams.items, 0..) |team, i| {
            quick_team.meta[i] = .{
                .name = try .fromSlice(team.name),
                .avatar_ids = @splat(.none),
                .buddy_id = @fromBackingInt(@intCast(team.buddy_id)),
            };

            const count = @min(QuickTeam.avatar_slots, team.avatar_ids.items.len);
            @memcpy(
                @as([*]u32, @ptrCast(&quick_team.meta[i].avatar_ids))[0..count],
                team.avatar_ids.items[0..count],
            );
        }
    } else {
        properties.quick_team = .init;
    }
}
