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

pub const List = rmmem.RemielleArrayList(
    rmmem.suggestBucketSize(64, Properties),
    Properties,
    u32,
);

pub fn setDefaultsAt(list: *List, time: Io.Timestamp, at: Player) void {
    const index = at.toInt();

    list.getPtr(.basic_info, index).* = .init;
    list.getPtr(.player_accessory, index).* = .init;
    list.getPtr(.avatar, index).* = .init;
    list.getPtr(.buddy, index).* = .init;
    list.getPtr(.weapon, index).* = .init;
    list.getPtr(.equip, index).* = .init;
    list.getPtr(.hall, index).* = .init;
    list.getPtr(.main_city_time, index).* = .init;
    list.getPtr(.quick_team, index).* = .init;

    unlockAllAvatars(list, at);
    applyAvatarOverrides(list, at);
    unlockAllBuddies(list, at);
    unlockAllWeapons(list, at);
    addConfiguredWeapons(list, at);
    addConfiguredEquipment(list, at);
    addRandomEquipment(list, time, at);
}

fn unlockAllAvatars(props: *Properties.List, at: Player) void {
    const avatar = props.getPtr(.avatar, at.toInt());

    for (templates.avatar_base.entries) |template| if (template.camp != 0) {
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
            level.* = .maxFor(@enumFromInt(skill_type));

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

fn applyAvatarOverrides(props: *Properties.List, at: Player) void {
    const avatar = props.getPtr(.avatar, at.toInt());

    inline for (@import("config").starting_items.avatar_overrides) |override| {
        const Override = @TypeOf(override);

        const index = avatar.indexes.get(override.id).?;
        const meta = &avatar.meta[index];

        if (@hasField(Override, "level"))
            meta.level = @enumFromInt(override.level);

        if (@hasField(Override, "rank"))
            meta.rank = @enumFromInt(override.rank);

        if (@hasField(Override, "talents"))
            meta.talents = @enumFromInt(override.talents);

        if (@hasField(Override, "awakening")) {
            meta.awakening = @enumFromInt(override.awakening);
            meta.flags.awake_available = true;
            meta.flags.awake_enabled = true;
        }
    }
}

fn unlockAllBuddies(props: *Properties.List, at: Player) void {
    const buddy = props.getPtr(.buddy, at.toInt());

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

        inline for (std.meta.fields(Properties.Buddy.Skill)) |field| {
            const skill: Properties.Buddy.Skill = @enumFromInt(field.value);
            buddy.meta[i].skill_levels.set(skill, .maxFor(skill));
        }
    };
}

fn unlockAllWeapons(props: *Properties.List, at: Player) void {
    const weapon = props.getPtr(.weapon, at.toInt());

    for (templates.weapon.entries) |template| {
        defer weapon.count += 1;
        const i = weapon.count;

        weapon.uids[i] = @enumFromInt(i);
        weapon.ids[i] = template.getId();
        weapon.levels[i] = .max;
        weapon.stars[i] = .max;
        weapon.refines[i] = .max;
    }
}

fn addConfiguredWeapons(props: *Properties.List, at: Player) void {
    const weapon = props.getPtr(.weapon, at.toInt());

    inline for (@import("config").starting_items.weapons) |entry| {
        defer weapon.count += 1;
        const i = weapon.count;

        weapon.uids[i] = @enumFromInt(i);
        weapon.ids[i] = entry.id;
        weapon.levels[i] = @enumFromInt(entry.level);
        weapon.stars[i] = @enumFromInt(entry.star);
        weapon.refines[i] = @enumFromInt(entry.refine);
    }
}

// TODO: Remove after server control protocol is implemented.
fn addConfiguredEquipment(props: *Properties.List, at: Player) void {
    const equip: *Properties.Equipment = props.getPtr(.equip, at.toInt());

    inline for (@import("config").starting_items.equipment) |entry| {
        defer equip.count += 1;
        const i = equip.count;

        equip.uids[i] = @enumFromInt(i);
        equip.ids[i] = entry.id;
        equip.levels[i] = @enumFromInt(entry.level);
        equip.stars[i] = @enumFromInt(entry.star);

        inline for (entry.properties, &equip.properties[i]) |config, *property|
            property.* = .{
                .key = @enumFromInt(config.key),
                .base_value = config.base_value,
                .add_value = config.add_value,
            };
    }
}

fn addRandomEquipment(props: *Properties.List, time: Io.Timestamp, at: Player) void {
    if (!@hasField(@TypeOf(@import("config").starting_items), "random_equipment"))
        return;

    const configured_count: u32 = @import("config").starting_items.random_equipment;
    const equip = props.getPtr(.equip, at.toInt());

    var add_count = @min(configured_count, Equipment.capacity - equip.count);

    var rng_impl: Random.DefaultPrng = .init(@bitCast(time.toSeconds()));
    const rng = rng_impl.random();

    while (add_count > 0) : (add_count -= 1) {
        const slot = (rng.int(u8) % 6) + 1;
        const suit_index = rng.int(usize) % templates.equipment_suit.entries.len;
        const suit_id = templates.equipment_suit.entries[suit_index].id;
        const equip_id = suit_id + 40 + slot;

        defer equip.count += 1;
        const i = equip.count;

        equip.uids[i] = @enumFromInt(i);
        equip.ids[i] = equip_id;
        equip.levels[i] = .max;
        equip.stars[i] = .max;

        genRandEquipmentProperties(rng, slot, &equip.properties[i]);
    }
}

const rand_table: RandTable = .init(.{
    .{ 11103, &.{1}, 550, 112 },
    .{ 11102, &.{ 4, 5, 6 }, 750, 300 },
    .{ 12103, &.{2}, 79, 19 },
    .{ 12102, &.{ 4, 5, 6 }, 750, 300 },
    .{ 13103, &.{3}, 46, 15 },
    .{ 13102, &.{ 4, 5, 6 }, 1200, 480 },
    .{ 23203, &.{}, 0, 9 },
    .{ 23103, &.{5}, 600, null },
    .{ 31402, &.{6}, 750, null },
    .{ 31203, &.{4}, 23, 9 },
    .{ 21103, &.{4}, 1200, 480 },
    .{ 20103, &.{4}, 600, 240 },
    .{ 30502, &.{6}, 1500, null },
    .{ 12202, &.{6}, 450, null },
    .{ 31803, &.{5}, 750, null },
    .{ 31903, &.{5}, 750, null },
    .{ 31603, &.{5}, 750, null },
    .{ 31703, &.{5}, 750, null },
    .{ 31503, &.{5}, 750, null },
    .{ 32303, &.{5}, 750, null },
});

const RandTable = struct {
    const count = 20;

    keys: [count]u16,
    main_property_slots: [count][]const u8,
    main_base_value: [count]u16,
    rand_base_value: [count]?u16,

    pub fn init(values: [count]struct { u16, []const u8, u16, ?u16 }) RandTable {
        var table: RandTable = undefined;

        for (
            values,
            &table.keys,
            &table.main_property_slots,
            &table.main_base_value,
            &table.rand_base_value,
        ) |value, *key, *main_slots, *main_base_value, *rand_base_value| {
            key.* = value[0];
            main_slots.* = value[1];
            main_base_value.* = value[2];
            rand_base_value.* = value[3];
        }

        return table;
    }
};

fn genRandEquipmentProperties(random: Random, slot: u8, out: *Equipment.Property.List) void {
    var properties_buf: [RandTable.count]usize = undefined;
    var main_properties: std.ArrayList(usize) = .initBuffer(&properties_buf);

    for (&rand_table.main_property_slots, 0..) |main_property_slots, i| {
        if (std.mem.findScalar(u8, main_property_slots, slot) != null)
            main_properties.appendAssumeCapacity(i);
    }

    const main_property_i = main_properties.items[random.int(u8) % main_properties.items.len];

    out[0] = .{
        .key = @enumFromInt(rand_table.keys[main_property_i]),
        .base_value = rand_table.main_base_value[main_property_i],
        .add_value = 1,
    };

    var select_rand_properties: std.ArrayList(usize) = .initBuffer(&properties_buf);

    for (&rand_table.rand_base_value, 0..) |rand_base_value, i| {
        if (rand_base_value == null) continue;
        if (i == main_property_i) continue;

        select_rand_properties.appendAssumeCapacity(i);
    }

    var add_value_mod: u8 = 5;

    for (out[1..], 1..) |*property, index| {
        const selected = random.int(u8) % select_rand_properties.items.len;
        const rand_i = select_rand_properties.items[selected];

        const add_value = if (index == Equipment.Property.count - 1)
            add_value_mod
        else
            random.int(u8) % add_value_mod;

        add_value_mod -= add_value;

        property.* = .{
            .key = @enumFromInt(rand_table.keys[rand_i]),
            .base_value = rand_table.rand_base_value[rand_i].?,
            .add_value = 1 + add_value,
        };

        _ = select_rand_properties.swapRemove(selected);
    }
}

pub const immutable_subset_marker_name = "logic_properties_subset_marker";

pub const mutable_subset_marker_name = "logic_properties_subset_marker";

pub fn Immutable(comptime types: anytype) type {
    return Subset(types, .immutable);
}

pub fn Mutable(comptime types: anytype) type {
    return Subset(types, .mutable);
}

fn Subset(
    /// A tuple of input types (fields of logic.Properties)
    comptime types: anytype,
    comptime access: enum { immutable, mutable },
) type {
    var field_types: [types.len + 1]type = undefined;
    var field_names: [types.len + 1][]const u8 = undefined;

    const properties_fields = @typeInfo(Properties).@"struct".fields;

    // Add a ZST field as a marker
    field_types[0] = void;
    field_names[0] = switch (access) {
        .immutable => immutable_subset_marker_name,
        .mutable => mutable_subset_marker_name,
    };

    for (types, field_types[1..], field_names[1..]) |P, *field_type, *field_name| {
        search: for (properties_fields) |properties_field| {
            if (properties_field.type == P) {
                field_type.* = switch (access) {
                    .immutable => *const P,
                    .mutable => *P,
                };

                field_name.* = properties_field.name;
                break :search;
            }
        } else @compileError("Invalid property type: " ++ @typeName(P));
    }

    return @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
}

pub fn extractFor(properties: *Properties.List, comptime Sub: type, index: u32) Sub {
    var subset: Sub = undefined;

    const bucket = properties.buckets.items[index / Properties.List.bucket_capacity];
    const i = index % Properties.List.bucket_capacity;

    inline for (@typeInfo(Sub).@"struct".fields) |field| {
        if (field.type == void) continue;

        @field(subset, field.name) = &@field(bucket, field.name)[i];
    }

    return subset;
}

/// Player index.
pub const Player = enum(u32) {
    _,

    pub fn toInt(player: Player) u32 {
        return @intFromEnum(player);
    }
};

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
            return @mod(@intFromEnum(time_period) * 360, 1440);
        }

        pub inline fn fromTimeInMinutes(time_in_minutes: u11) TimePeriod {
            const t = @mod(time_in_minutes, 1440) / 360;
            return @enumFromInt(if (t == 0) 4 else t);
        }

        pub inline fn isNextDayOf(next: TimePeriod, prev: TimePeriod) bool {
            return @intFromEnum(prev) > @intFromEnum(next);
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
            return @enumFromInt(@mod(@intFromEnum(day) + 1, 7));
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
        return @intFromEnum(level);
    }
};

pub const HallAvatar = enum(u32) {
    none = 0,
    wise = @intFromEnum(templates.avatar_base.Id.wise),
    belle = @intFromEnum(templates.avatar_base.Id.belle),

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
        return @intFromEnum(avatar);
    }

    pub const Guise = enum(u32) {
        none = 0,
        wise = @intFromEnum(HallAvatar.wise),
        belle = @intFromEnum(HallAvatar.belle),
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
                    const index = player_avatar_prop.indexes.get(@enumFromInt(guise_avatar_id.toInt())).?;
                    break :guise_avatar_id player_avatar_prop.meta[index].skin;
                },
            };
        }

        pub fn fromIdUnchecked(id: templates.avatar_base.Id) Guise {
            return @enumFromInt(@intFromEnum(id));
        }

        pub fn toInt(guise: Guise) u32 {
            return @intFromEnum(guise);
        }
    };
};

pub fn toPlayerSave(props: *Properties.List, arena: Allocator, player: Player) Allocator.Error!pb.PlayerSave {
    const index = @intFromEnum(player);

    const basic_info = props.getPtr(.basic_info, index);
    const basic_save: pb.BasicSave = .{
        .level = basic_info.level.toInt(),
        .avatar_id = basic_info.avatar.toInt(),
        .control_avatar_id = basic_info.control_avatar.toInt(),
        .control_guise_avatar_id = basic_info.control_guise_avatar.toInt(),
        .control_guise_avatar_skin_id = basic_info.control_guise_avatar_skin.toInt(),
    };

    const player_accessory = props.getPtr(.player_accessory, index);

    var player_accessory_save: pb.PlayerAccessorySave = .init;
    try player_accessory_save.avatars.ensureTotalCapacity(arena, PlayerAccessory.slots);

    inline for (std.enums.values(PlayerAccessory.Avatar)) |avatar| player_accessory_save.avatars.appendAssumeCapacity(.{
        .id = @intFromEnum(avatar),
        .skin_id = @intFromEnum(player_accessory.meta.get(avatar).skin),
    });

    const avatar = props.getPtr(.avatar, index);
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
            .id = @intFromEnum(id),
            .level = meta.level.toInt(),
            .exp = meta.exp,
            .rank = meta.rank.toInt(),
            .talents = meta.talents.toInt(),
            .mindscape_tab_state = @intFromEnum(meta.mindscape_tab_state),
            .favorite = meta.flags.favorite,
            .skill_levels = skill_levels,
            .skin_id = meta.skin.toInt(),
            .awake_available = meta.flags.awake_available,
            .awake_enabled = meta.flags.awake_enabled,
            .awake_id = meta.awakening.toInt(),
            .show_weapon = @intFromEnum(meta.flags.show_weapon),
            .weapon_uid = @intFromEnum(weapon_uid),
            .equipment_uids = .fromOwnedSlice(try arena.dupe(u32, @ptrCast(equipment_uids))),
            .awake_material_count = awake_material_count.toInt(),
        });
    }

    const buddy = props.getPtr(.buddy, index);
    const buddy_count = buddy.indexes.count();

    var buddy_save: pb.BuddySave = .init;
    try buddy_save.items.ensureTotalCapacity(arena, buddy_count);

    for (buddy.ids[0..buddy_count], buddy.meta[0..buddy_count]) |id, *meta| {
        var skill_levels: std.ArrayList(u32) = try .initCapacity(arena, Properties.Buddy.Skill.Levels.len);

        inline for (std.meta.fields(Properties.Buddy.Skill)) |field| {
            const skill: Properties.Buddy.Skill = @enumFromInt(field.value);
            skill_levels.appendAssumeCapacity(meta.skill_levels.get(skill).toInt());
        }

        buddy_save.items.appendAssumeCapacity(.{
            .id = @intFromEnum(id),
            .level = meta.level.toInt(),
            .exp = meta.exp,
            .rank = meta.rank.toInt(),
            .star = meta.star.toInt(),
            .favorite = meta.flags.favorite,
            .skill_levels = skill_levels,
        });
    }

    const weapon = props.getPtr(.weapon, index);
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
            .id = @intFromEnum(id),
            .uid = @intFromEnum(uid),
            .level = level.toInt(),
            .star = star.toInt(),
            .refine = refine.toInt(),
        });
    }

    const equip: *Equipment = props.getPtr(.equip, index);
    var equip_save: pb.EquipSave = .init;
    try equip_save.items.ensureTotalCapacity(arena, equip.count);

    for (
        equip.uids[0..equip.count],
        equip.ids[0..equip.count],
        equip.levels[0..equip.count],
        equip.stars[0..equip.count],
        equip.properties[0..equip.count],
    ) |uid, id, level, star, *properties| {
        var equip_properties: std.ArrayList(pb.EquipProperty) = try .initCapacity(
            arena,
            Equipment.Property.count,
        );

        for (properties) |*prop| equip_properties.appendAssumeCapacity(.{
            .key = @intFromEnum(prop.key),
            .base_value = prop.base_value,
            .add_value = prop.add_value,
        });

        equip_save.items.appendAssumeCapacity(.{
            .uid = @intFromEnum(uid),
            .id = id,
            .level = level.toInt(),
            .star = star.toInt(),
            .properties = equip_properties,
        });
    }

    const hall = props.getPtr(.hall, index);
    const hall_save: pb.HallSave = .{
        .section_id = @intFromEnum(hall.section_id),
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

    const main_city_time = props.getPtr(.main_city_time, index);
    const main_city_time_save: pb.MainCityTimeSave = .{
        .time_in_minutes = main_city_time.time_in_minutes,
        .day_of_week = @intFromEnum(main_city_time.day_of_week),
    };

    const quick_team = props.getPtr(.quick_team, index);
    var quick_team_save: pb.QuickTeamSave = .{
        .teams = try .initCapacity(arena, QuickTeam.slots),
    };

    for (&quick_team.meta) |*meta| {
        const team = quick_team_save.teams.addOneAssumeCapacity();

        team.* = .{
            .name = meta.name.view(),
            .avatar_ids = try .initCapacity(arena, Properties.QuickTeam.avatar_slots),
            .buddy_id = @intFromEnum(meta.buddy_id),
        };

        for (meta.avatar_ids) |avatar_id|
            team.avatar_ids.appendAssumeCapacity(@intFromEnum(avatar_id));
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
    props: *Properties.List,
    player: Player,
    save: *const pb.PlayerSave,
) !void {
    const index = @intFromEnum(player);
    props.getPtr(.basic_info, index).* = if (save.basic) |basic| .{
        .level = @enumFromInt(basic.level),
        .avatar = @enumFromInt(basic.avatar_id),
        .control_avatar = @enumFromInt(basic.control_avatar_id),
        .control_guise_avatar = @enumFromInt(basic.control_guise_avatar_id),
        .control_guise_avatar_skin = @enumFromInt(basic.control_guise_avatar_skin_id),
    } else .init;

    const player_accessory = props.getPtr(.player_accessory, index);
    player_accessory.* = .init;

    if (save.player_accessory) |player_accessory_save|
        for (player_accessory_save.avatars.items) |avatar|
            player_accessory.meta.set(@enumFromInt(avatar.id), .{ .skin = @enumFromInt(avatar.skin_id) });

    if (save.avatar) |avatar_save| {
        const avatar = props.getPtr(.avatar, index);
        avatar.* = .init;

        for (avatar_save.items.items, 0..) |*item, i| {
            avatar.indexes.put(@enumFromInt(item.id), @intCast(i));
            avatar.ids[i] = @enumFromInt(item.id);

            avatar.meta[i] = .{
                .level = @enumFromInt(item.level),
                .exp = item.exp,
                .rank = @enumFromInt(item.rank),
                .talents = @enumFromInt(item.talents),
                .mindscape_tab_state = @enumFromInt(item.mindscape_tab_state),
                .flags = .{
                    .favorite = item.favorite,
                    .awake_available = item.awake_available,
                    .awake_enabled = item.awake_enabled,
                    .show_weapon = @enumFromInt(item.show_weapon),
                },
                .skill_levels = undefined,
                .skin = @enumFromInt(item.skin_id),
                .awakening = @enumFromInt(item.awake_id),
            };

            inline for (&avatar.meta[i].skill_levels, 0..) |*level, skill_i|
                level.* = if (item.skill_levels.items.len > skill_i)
                    @enumFromInt(item.skill_levels.items[skill_i])
                else
                    .maxFor(@enumFromInt(skill_i));

            avatar.weapon_uids[i] = @enumFromInt(item.weapon_uid);

            for (&avatar.equipment_uids[i], 0..) |*equipment_uid, slot_i|
                equipment_uid.* = if (item.equipment_uids.items.len > slot_i)
                    @enumFromInt(item.equipment_uids.items[slot_i])
                else
                    .none;

            avatar.awake_material_counts[i] = @enumFromInt(item.awake_material_count);
        }
    } else {
        props.getPtr(.avatar, index).* = .init;
        unlockAllAvatars(props, player);
        applyAvatarOverrides(props, player);
    }

    if (save.buddy) |buddy_save| {
        const buddy = props.getPtr(.buddy, index);
        buddy.* = .init;

        for (buddy_save.items.items, 0..) |*item, i| {
            buddy.indexes.put(@enumFromInt(item.id), @intCast(i));
            buddy.ids[i] = @enumFromInt(item.id);

            buddy.meta[i] = .{
                .level = @enumFromInt(item.level),
                .exp = item.exp,
                .rank = @enumFromInt(item.rank),
                .star = @enumFromInt(item.star),
                .skill_levels = .initUndefined(),
                .flags = .{
                    .favorite = item.favorite,
                },
            };

            inline for (std.meta.fields(Properties.Buddy.Skill), 0..) |field, skill_i| {
                const skill: Properties.Buddy.Skill = @enumFromInt(field.value);
                buddy.meta[i].skill_levels.set(skill, if (item.skill_levels.items.len > skill_i)
                    @enumFromInt(item.skill_levels.items[skill_i])
                else
                    .maxFor(skill));
            }
        }
    } else {
        props.getPtr(.buddy, index).* = .init;
        unlockAllBuddies(props, player);
    }

    if (save.weapon) |weapon_save| {
        const weapon = props.getPtr(.weapon, index);
        weapon.* = .init;

        weapon.count = @intCast(weapon_save.items.items.len);

        for (weapon_save.items.items, 0..) |*item, i| {
            weapon.uids[i] = @enumFromInt(item.uid);
            weapon.ids[i] = @enumFromInt(item.id);
            weapon.levels[i] = @enumFromInt(item.level);
            weapon.stars[i] = @enumFromInt(item.star);
            weapon.refines[i] = @enumFromInt(item.refine);
        }
    } else {
        props.getPtr(.weapon, index).* = .init;
        unlockAllWeapons(props, player);
        addConfiguredWeapons(props, player);
    }

    if (save.equip) |equip_save| {
        const equip = props.getPtr(.equip, index);
        equip.* = .init;

        equip.count = @intCast(equip_save.items.items.len);

        for (equip_save.items.items, 0..) |*item, i| {
            equip.uids[i] = @enumFromInt(item.uid);
            equip.ids[i] = item.id;
            equip.levels[i] = @enumFromInt(item.level);
            equip.stars[i] = @enumFromInt(item.star);
            equip.properties[i] = @splat(.none);

            const prop_count = @min(item.properties.items.len, Equipment.Property.count);

            for (item.properties.items[0..prop_count], equip.properties[i][0..prop_count]) |saved, *property|
                property.* = .{
                    .key = @enumFromInt(saved.key),
                    .base_value = @truncate(saved.base_value),
                    .add_value = @truncate(saved.add_value),
                };
        }
    } else {
        props.getPtr(.equip, index).* = .init;
        addConfiguredEquipment(props, player);
    }

    props.getPtr(.hall, index).* = if (save.hall) |hall_save| .{
        .section_id = @enumFromInt(hall_save.section_id),
        .position = (if (hall_save.position_transform) |transform|
            Hall.Position.fromVectors(
                transform.position.items,
                transform.rotation.items,
            )
        else
            Hall.Position.fromId(hall_save.position_id)) orelse .init,
    } else .init;

    props.getPtr(.main_city_time, index).* = if (save.main_city_time) |main_city_time_save| .{
        .time_in_minutes = @truncate(main_city_time_save.time_in_minutes),
        .day_of_week = @enumFromInt(main_city_time_save.day_of_week),
    } else .init;

    if (save.quick_team) |quick_team_save| {
        const quick_team = props.getPtr(.quick_team, index);

        for (quick_team_save.teams.items, 0..) |team, i| {
            quick_team.meta[i] = .{
                .name = try .fromSlice(team.name),
                .avatar_ids = @splat(.none),
                .buddy_id = @enumFromInt(team.buddy_id),
            };

            const count = @min(QuickTeam.avatar_slots, team.avatar_ids.items.len);
            @memcpy(
                @as([*]u32, @ptrCast(&quick_team.meta[i].avatar_ids))[0..count],
                team.avatar_ids.items[0..count],
            );
        }
    } else {
        props.getPtr(.quick_team, index).* = .init;
    }
}

const Io = std.Io;
const Random = std.Random;
const Allocator = std.mem.Allocator;

const templates = Assets.templates;

const Assets = @import("../Assets.zig");

const pb = @import("rmpb").stable;
const rmmem = @import("rmmem");
const std = @import("std");

const Properties = @This();
