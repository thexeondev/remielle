const rupture_weapon_type: u32 = 6;

fn applyCoreSkillBonus(map: *Property.Map, id: u32, level: u32) void {
    inline for (core_skill_specials) |bonus| {
        const avatar_id, const bonus_prop, const scale_prop, const percentage = bonus;
        if (avatar_id == id) {
            const bonus_value = @divFloor(getProperty(map, scale_prop) * percentage[level - 1], 100);
            modifyProperty(map, bonus_prop, bonus_value);
        }
    }
}

fn initEquipmentSuitProperties(
    map: *Property.Map,
    indexes: []const u32,
    equipment: *const logic.Properties.Equipment,
) void {
    var suit_ids: [logic.Properties.Avatar.equipment_slots]u32 = undefined;
    var suit_times: [logic.Properties.Avatar.equipment_slots]u32 = undefined;
    var suit_count: u32 = 0;

    for (indexes) |index| {
        const id = equipment.ids[index];
        const suit_id = (id / 100) * 100;

        if (std.mem.findScalar(u32, suit_ids[0..suit_count], suit_id)) |suit_index|
            suit_times[suit_index] += 1
        else {
            suit_ids[suit_count] = suit_id;
            suit_times[suit_count] = 1;
            suit_count += 1;
        }
    }

    for (suit_ids[0..suit_count], suit_times[0..suit_count]) |suit_id, count| {
        for (templates.equipment_suit.entries) |entry| if (entry.id == suit_id) {
            if (count >= entry.primary_condition) {
                for (entry.primary_suit_propertys) |prop| {
                    const property = std.enums.fromInt(Property, prop.property) orelse
                        continue;

                    modifyProperty(map, property, prop.value);
                }
            }

            break;
        };
    }
}

fn initEquipmentProperties(
    map: *Property.Map,
    indexes: []const u32,
    equipment: *const logic.Properties.Equipment,
) void {
    const divisor: f32 = 10_000;

    for (indexes) |index| {
        const equip_id = equipment.ids[index];
        const equip_level = equipment.levels[index].toInt();
        const rarity: u32 = (equip_id / 10) % 10;

        const rate: f32 = rate: {
            for (templates.equipment_level.entries) |*entry| {
                if (entry.rarity == rarity and entry.level == equip_level)
                    break :rate @floatFromInt(entry.property_rate);
            }

            break :rate 1;
        };

        if (equipment.properties[index][0].key.unwrap()) |key_int| {
            const key = std.enums.fromInt(Property, key_int) orelse
                continue;

            const base: f32 = @floatFromInt(equipment.properties[index][0].base_value);
            const value: i32 = @intFromFloat(base + (base * rate / divisor));
            modifyProperty(map, key, value);
        }

        for (equipment.properties[index][1..]) |prop| {
            if (prop.key.unwrap()) |key_int| {
                const key = std.enums.fromInt(Property, key_int) orelse
                    continue;

                const base: f32 = @floatFromInt(prop.base_value);
                const add: f32 = @floatFromInt(prop.add_value);
                modifyProperty(map, key, @intFromFloat(base * add));
            }
        }
    }
}

fn initWeaponProperties(
    map: *Property.Map,
    weapon: *const templates.weapon.Template,
    level: *const templates.weapon_level.Template,
    star: *const templates.weapon_star.Template,
) void {
    const divisor: f32 = 10_000;

    const level_rate: f32 = @floatFromInt(level.rate);
    const star_rate: f32 = @floatFromInt(star.star_rate);
    const rand_rate: f32 = @floatFromInt(star.rand_rate);

    const base_property_base_value: f32 = @floatFromInt(weapon.base_property.value);
    const base_property_level_rate: i32 = @intFromFloat((base_property_base_value * level_rate) / divisor);
    const base_property_star_rate: i32 = @intFromFloat((base_property_base_value * star_rate) / divisor);

    if (std.enums.fromInt(Property, weapon.base_property.property)) |base_property| {
        modifyProperty(map, base_property, @as(i32, @intFromFloat(base_property_base_value)) + base_property_level_rate + base_property_star_rate);
    }

    const rand_property_base_value: f32 = @floatFromInt(weapon.rand_property.value);
    const rand_property_rate: i32 = @intFromFloat((rand_property_base_value * rand_rate) / divisor);

    if (std.enums.fromInt(Property, weapon.rand_property.property)) |rand_property| {
        modifyProperty(map, rand_property, @as(i32, @intFromFloat(rand_property_base_value)) + rand_property_rate);
    }
}

fn setBattleProperties(map: *Property.Map) void {
    // Set *Battle variants of properties.
    setProperty(map, .HpMaxBattle, getProperty(map, .HpMax));
    setProperty(map, .AtkBattle, getProperty(map, .Atk));
    setProperty(map, .BreakStunBattle, getProperty(map, .BreakStun));
    setProperty(map, .SkipDefAtkBattle, getProperty(map, .SkipDefAtk));
    setProperty(map, .DefBattle, getProperty(map, .Def));
    setProperty(map, .CritBattle, getProperty(map, .Crit));
    setProperty(map, .CritDmgBattle, getProperty(map, .CritDmg));
    setProperty(map, .SharpCriticalDamageBattle, getProperty(map, .SharpCriticalDamage));
    setProperty(map, .SpRecoverBattle, getProperty(map, .SpRecover));
    setProperty(map, .ElementMysteryBattle, getProperty(map, .ElementMystery));
    setProperty(map, .ElementAbnormalPowerBattle, getProperty(map, .ElementAbnormalPower));
    setProperty(map, .AddedDamageRatioBattle, getProperty(map, .AddedDamageRatio));
    setProperty(map, .AddedDamageRatioPhysicsBattle, getProperty(map, .AddedDamageRatioPhysics));
    setProperty(map, .AddedDamageRatioFireBattle, getProperty(map, .AddedDamageRatioFire));
    setProperty(map, .AddedDamageRatioIceBattle, getProperty(map, .AddedDamageRatioIce));
    setProperty(map, .AddedDamageRatioElecBattle, getProperty(map, .AddedDamageRatioElec));
    setProperty(map, .AddedDamageRatioEtherBattle, getProperty(map, .AddedDamageRatioEther));
    setProperty(map, .RpRecoverBattle, getProperty(map, .RpRecover));
    setProperty(map, .SkipDefDamageRatioBattle, getProperty(map, .SkipDefDamageRatio));
    setProperty(map, .AddedDamageRatioWindBattle, getProperty(map, .AddedDamageRatioWind));
    setProperty(map, .EpRecoverBattle, getProperty(map, .EpRecover));
    modifyProperty(map, .PenRatioBattle, getProperty(map, .Pen));
    modifyProperty(map, .PenDeltaBattle, getProperty(map, .PenValue));

    // Set current HP
    modifyProperty(map, .Hp, getProperty(map, .HpMax));
}

fn setDynamicProperties(map: *Property.Map) void {
    setDynamicProperty(map, .HpMax, .HpMaxBase, .HpMaxRatio, .HpMaxDelta);
    setDynamicProperty(map, .SpMax, .SpMaxBase, .None, .SpMaxDelta);
    setDynamicProperty(map, .RpMax, .RpMaxBase, .None, .RpMaxDelta);
    setDynamicProperty(map, .EpMax, .EpMaxBase, .None, .EpMaxDelta);
    setDynamicProperty(map, .Atk, .AtkBase, .AtkRatio, .AtkDelta);
    setDynamicProperty(map, .BreakStun, .BreakStunBase, .BreakStunRatio, .BreakStunDelta);
    setDynamicProperty(map, .SkipDefAtk, .SkipDefAtkBase, .None, .SkipDefAtkDelta);
    setDynamicProperty(map, .Def, .DefBase, .DefRatio, .DefDelta);
    setDynamicProperty(map, .Crit, .CritBase, .None, .CritDelta);
    setDynamicProperty(map, .CritDmg, .CritDmgBase, .None, .CritDmgDelta);
    setDynamicProperty(map, .SharpCriticalDamage, .SharpCriticalDamageBase, .None, .SharpCriticalDamageDelta);
    setDynamicProperty(map, .Pen, .PenBase, .None, .PenDelta);
    setDynamicProperty(map, .PenValue, .PenValueBase, .None, .PenValueDelta);
    setDynamicProperty(map, .SpRecover, .SpRecoverBase, .SpRecoverRatio, .SpRecoverDelta);
    setDynamicProperty(map, .RpRecover, .RpRecoverBase, .RpRecoverRatio, .RpRecoverDelta);
    setDynamicProperty(map, .EpRecover, .EpRecoverBase, .EpRecoverRatio, .EpRecoverDelta);
    setDynamicProperty(map, .ElementMystery, .ElementMysteryBase, .None, .ElementMysteryDelta);
    setDynamicProperty(map, .ElementAbnormalPower, .ElementAbnormalPowerBase, .ElementAbnormalPowerRatio, .ElementAbnormalPowerDelta);
    setDynamicProperty(map, .AddedDamageRatio, .AddedDamageRatio1, .None, .AddedDamageRatio3);
    setDynamicProperty(map, .AddedDamageRatioPhysics, .AddedDamageRatioPhysics1, .None, .AddedDamageRatioPhysics3);
    setDynamicProperty(map, .AddedDamageRatioFire, .AddedDamageRatioFire1, .None, .AddedDamageRatioFire3);
    setDynamicProperty(map, .AddedDamageRatioIce, .AddedDamageRatioIce1, .None, .AddedDamageRatioIce3);
    setDynamicProperty(map, .AddedDamageRatioElec, .AddedDamageRatioElec1, .None, .AddedDamageRatioElec3);
    setDynamicProperty(map, .AddedDamageRatioEther, .AddedDamageRatioEther1, .None, .AddedDamageRatioEther3);
    setDynamicProperty(map, .SkipDefDamageRatio, .SkipDefDamageRatio1, .None, .SkipDefDamageRatio3);
    setDynamicProperty(map, .AddedDamageRatioWind, .AddedDamageRatioWind1, .None, .AddedDamageRatioWind3);
}

fn setDynamicProperty(map: *Property.Map, prop: Property, base_prop: Property, ratio_prop: Property, delta_prop: Property) void {
    const divisor: f32 = 10_000.0;

    const base = getProperty(map, base_prop);
    const delta = getProperty(map, delta_prop);

    const base_float: f32 = @floatFromInt(base);
    const ratio: f32 = @floatFromInt(getProperty(map, ratio_prop));

    var scaled_base = (base_float * ratio) / divisor;
    if (prop == .HpMax) {
        scaled_base = @ceil(scaled_base);
    }

    setProperty(map, prop, base + @as(i32, @intFromFloat(scaled_base)) + delta);
}

fn applyPassiveSkillProperties(map: *Property.Map, template: *const templates.avatar_passive_skill.Template) void {
    for (template.propertys) |prop| {
        const key = std.enums.fromInt(Property, prop.property) orelse
            continue;

        modifyProperty(map, key, prop.value);
    }
}

fn growPropertyByLevel(map: *Property.Map, level: u32, base_prop: Property, growth_prop: Property, advance_prop: Property) void {
    const divisor: f32 = 10_000.0;

    const base = map.get(base_prop).?;
    const advance = map.get(advance_prop).?;
    const growth: f32 = @floatFromInt(map.get(growth_prop).?);
    const level_float: f32 = @floatFromInt(level - 1);

    const add: i32 = @intFromFloat((level_float * growth) / divisor);
    setProperty(map, base_prop, base + add + advance);
}

fn initLevelAdvanceProperties(map: *Property.Map, template: *const templates.avatar_level_advance.Template) void {
    setProperty(map, .HpMaxAdvance, template.hp_max);
    setProperty(map, .AtkAdvance, template.attack);
    setProperty(map, .DefAdvance, template.defence);
}

fn initBaseProperties(map: *Property.Map, template: *const templates.avatar_battle.Template) void {
    setProperty(map, .HpMaxBase, template.hp_max);
    setProperty(map, .HpMaxGrowth, template.health_growth);
    setProperty(map, .AtkBase, template.attack);
    setProperty(map, .AtkGrowth, template.attack_growth);
    setProperty(map, .BreakStunBase, template.break_stun);
    setProperty(map, .DefBase, template.defence);
    setProperty(map, .DefGrowth, template.defence_growth);
    setProperty(map, .CritBase, template.crit);
    setProperty(map, .CritDmgBase, template.crit_damage);
    setProperty(map, .SharpCriticalDamageBase, template.sharp_critical_damage);
    setProperty(map, .PenBase, 0);
    setProperty(map, .PenValueBase, 0);
    setProperty(map, .SpMaxBase, template.sp_bar_point);
    setProperty(map, .SpRecoverBase, template.sp_recover);
    setProperty(map, .ElementMysteryBase, template.element_mystery);
    setProperty(map, .ElementAbnormalPowerBase, template.element_abnormal_power);
    setProperty(map, .RpMax, template.rp_max);
    setProperty(map, .RpRecoverBase, template.rp_recover);
    setProperty(map, .EpMax, template.ep_max);
    setProperty(map, .EpRecoverBase, template.ep_recover);
}

fn modifyProperty(map: *Property.Map, key: Property, delta: i32) void {
    const current = map.get(key) orelse 0;
    setProperty(map, key, current + delta);
}

fn setProperty(map: *Property.Map, key: Property, value: i32) void {
    map.putAssumeCapacity(key, value);
}

fn getProperty(map: *const Property.Map, key: Property) i32 {
    return map.get(key) orelse 0;
}

fn clearCustomProperties(map: *Property.Map) void {
    _ = map.swapRemove(.HpMaxGrowth);
    _ = map.swapRemove(.AtkGrowth);
    _ = map.swapRemove(.DefGrowth);
    _ = map.swapRemove(.HpMaxAdvance);
    _ = map.swapRemove(.AtkAdvance);
    _ = map.swapRemove(.DefAdvance);
}

// TODO: find out where this is actually configured
const core_skill_specials = [_]struct { u32, Property, Property, [7]i32 }{
    // Yidhari - 10% HP -> SheerForce
    .{ 1051, .SkipDefAtk, .HpMax, @splat(10) },
    // Ben - 40-80% DEF -> ATK
    .{ 1121, .Atk, .Def, .{ 40, 46, 52, 60, 66, 72, 80 } },
    // Yixuan - 10% HP -> SheerForce
    .{ 1371, .SkipDefAtk, .HpMax, @splat(10) },
    // Komano Manato - 10% HP -> SheerForce
    .{ 1441, .SkipDefAtk, .HpMax, @splat(10) },
    // BanYue - 10% HP -> SheerForce
    .{ 1471, .SkipDefAtk, .HpMax, @splat(10) },
    // Starlight - Billy - 10% HP -> SheerForce
    .{ 1531, .SkipDefAtk, .HpMax, @splat(10) },
};

pub const Property = enum(u32) {
    // We cannot use EnumMap because of :backward_branch_limit_in_motorized_wheelchair:
    pub const Map = std.array_hash_map.Auto(Property, i32);

    pub fn createMap(
        arena: Allocator,
        avatar: *const logic.Properties.Avatar,
        weapon: *const logic.Properties.Weapon,
        equipment: *const logic.Properties.Equipment,
        avatar_id: templates.avatar_base.Id,
    ) Allocator.Error!Map {
        const avatar_index = avatar.indexes.get(avatar_id) orelse
            return .empty;

        const battle_template = battle_template: {
            for (templates.avatar_battle.entries) |*entry|
                if (entry.id == @intFromEnum(avatar_id))
                    break :battle_template entry;

            return .empty;
        };

        const avatar_meta = &avatar.meta[avatar_index];

        const level_advance_template = level_advance_template: {
            for (templates.avatar_level_advance.entries) |*entry| {
                if (entry.avatar_id == @intFromEnum(avatar_id) and entry.id == avatar_meta.rank.toInt()) {
                    break :level_advance_template entry;
                }
            }

            return .empty;
        };

        var map: Property.Map = .empty;
        try map.ensureTotalCapacity(arena, @typeInfo(Property).@"enum".fields.len);

        initBaseProperties(&map, battle_template);
        initLevelAdvanceProperties(&map, level_advance_template);

        const avatar_level = avatar_meta.level.toInt();

        growPropertyByLevel(&map, avatar_level, .HpMaxBase, .HpMaxGrowth, .HpMaxAdvance);
        growPropertyByLevel(&map, avatar_level, .AtkBase, .AtkGrowth, .AtkAdvance);
        growPropertyByLevel(&map, avatar_level, .DefBase, .DefGrowth, .DefAdvance);

        const passive_skill_level = avatar_meta.skill_levels[logic.Properties.Avatar.Skill.core_skill.toInt()].toInt() - 1;
        const avatar_passive_skill_id = @intFromEnum(avatar_id) * 1000 + passive_skill_level;

        for (templates.avatar_passive_skill.entries) |*entry| {
            if (entry.skill_id == avatar_passive_skill_id) {
                applyPassiveSkillProperties(&map, entry);
                break;
            }
        }

        if (avatar.weapon_uids[avatar_index].unwrap()) |weapon_uid_int| weapon: {
            const weapon_uid = logic.Properties.Weapon.Uid.fromInt(weapon_uid_int).?;
            const weapon_index = std.mem.findScalar(
                logic.Properties.Weapon.Uid,
                &weapon.uids,
                weapon_uid,
            ).?;

            const weapon_id = weapon.ids[weapon_index];
            const weapon_level = weapon.levels[weapon_index].toInt();
            const weapon_star = weapon.stars[weapon_index].toInt();
            const weapon_template = templates.weapon.map.get(weapon_id).?;

            const rarity: u32 = @mod(@divFloor(@intFromEnum(weapon_id), 1000), 10);

            const level_template = level_template: {
                for (templates.weapon_level.entries) |*entry| {
                    if (entry.rarity == rarity and entry.level == weapon_level)
                        break :level_template entry;
                }

                break :weapon;
            };

            const star_template = star_template: {
                for (templates.weapon_star.entries) |*entry| {
                    if (entry.rarity == rarity and entry.star == weapon_star)
                        break :star_template entry;
                }

                break :weapon;
            };

            initWeaponProperties(&map, weapon_template, level_template, star_template);
        }

        var equipment_indexes_buf: [logic.Properties.Avatar.equipment_slots]u32 = undefined;
        var equipment_indexes: std.ArrayList(u32) = .initBuffer(&equipment_indexes_buf);

        for (avatar.equipment_uids[avatar_index]) |optional_uid| if (optional_uid.unwrap()) |uid_int| {
            const uid = logic.Properties.Equipment.Uid.fromInt(uid_int).?;
            const index: u32 = @intCast(std.mem.findScalar(
                logic.Properties.Equipment.Uid,
                &equipment.uids,
                uid,
            ) orelse continue);

            equipment_indexes.appendAssumeCapacity(index);
        };

        initEquipmentProperties(&map, equipment_indexes.items, equipment);
        initEquipmentSuitProperties(&map, equipment_indexes.items, equipment);

        setDynamicProperties(&map);
        applyCoreSkillBonus(&map, @intFromEnum(avatar_id), avatar_meta.skill_levels[
            @intFromEnum(
                logic.Properties.Avatar.Skill.core_skill,
            )
        ].toInt());

        clearCustomProperties(&map);
        if (battle_template.weapon_type == rupture_weapon_type) {
            // Standard 30% ATK to Sheer Force conversion for Rupture agents
            modifyProperty(&map, .SkipDefAtk, @divFloor(getProperty(&map, .Atk) * 30, 100));
        }
        setBattleProperties(&map);

        return map;
    }

    None = 0,
    Hp = 1,
    HpMax = 111,
    SpMax = 115,
    RpMax = 119,
    EpMax = 120,
    Atk = 121,
    BreakStun = 122,
    SkipDefAtk = 123,
    Def = 131,
    Crit = 201,
    CritDmg = 211,
    SharpCriticalDamage = 213,
    Pen = 231,
    PenValue = 232,
    SpRecover = 305,
    AddedDamageRatio = 307,
    ElementMystery = 312,
    ElementAbnormalPower = 314,
    AddedDamageRatioPhysics = 315,
    AddedDamageRatioFire = 316,
    AddedDamageRatioIce = 317,
    AddedDamageRatioElec = 318,
    AddedDamageRatioEther = 319,
    RpRecover = 320,
    SkipDefDamageRatio = 322,
    AddedDamageRatioWind = 323,
    EpRecover = 324,
    // battle
    HpMaxBattle = 1111,
    AtkBattle = 1121,
    BreakStunBattle = 1122,
    SkipDefAtkBattle = 1123,
    DefBattle = 1131,
    CritBattle = 1201,
    CritDmgBattle = 1211,
    SharpCriticalDamageBattle = 1213,
    PenRatioBattle = 1231,
    PenDeltaBattle = 1232,
    SpRecoverBattle = 1305,
    AddedDamageRatioBattle = 1307,
    ElementMysteryBattle = 1312,
    ElementAbnormalPowerBattle = 1314,
    AddedDamageRatioPhysicsBattle = 1315,
    AddedDamageRatioFireBattle = 1316,
    AddedDamageRatioIceBattle = 1317,
    AddedDamageRatioElecBattle = 1318,
    AddedDamageRatioEtherBattle = 1319,
    RpRecoverBattle = 1320,
    SkipDefDamageRatioBattle = 1322,
    AddedDamageRatioWindBattle = 1323,
    EpRecoverBattle = 1324,
    // base
    HpMaxBase = 11101,
    SpMaxBase = 11501,
    RpMaxBase = 11901,
    EpMaxBase = 12001,
    AtkBase = 12101,
    BreakStunBase = 12201,
    SkipDefAtkBase = 12301, // ?? client has 12205 for some reason
    DefBase = 13101,
    CritBase = 20101,
    CritDmgBase = 21101,
    SharpCriticalDamageBase = 21301,
    PenBase = 23101,
    PenValueBase = 23201,
    SpRecoverBase = 30501,
    ElementMysteryBase = 31201,
    ElementAbnormalPowerBase = 31401,
    RpRecoverBase = 32001,
    EpRecoverBase = 32401,
    // ratio
    HpMaxRatio = 11102,
    AtkRatio = 12102,
    BreakStunRatio = 12202,
    DefRatio = 13102,
    SpRecoverRatio = 30502,
    ElementAbnormalPowerRatio = 31402,
    RpRecoverRatio = 32002,
    EpRecoverRatio = 32402,
    // delta
    HpMaxDelta = 11103,
    SpMaxDelta = 11503,
    RpMaxDelta = 11903,
    EpMaxDelta = 12003,
    AtkDelta = 12103,
    BreakStunDelta = 12203,
    SkipDefAtkDelta = 12303, // ?? client has 12205 for some reason
    DefDelta = 13103,
    CritDelta = 20103,
    CritDmgDelta = 21103,
    SharpCriticalDamageDelta = 21303,
    PenDelta = 23103,
    PenValueDelta = 23203,
    SpRecoverDelta = 30503,
    ElementMysteryDelta = 31203,
    ElementAbnormalPowerDelta = 31403,
    RpRecoverDelta = 32003,
    EpRecoverDelta = 32403,
    // damage ratios 1/3
    AddedDamageRatio1 = 30701,
    AddedDamageRatio3 = 30703,
    AddedDamageRatioPhysics1 = 31501,
    AddedDamageRatioPhysics3 = 31503,
    AddedDamageRatioFire1 = 31601,
    AddedDamageRatioFire3 = 31603,
    AddedDamageRatioIce1 = 31701,
    AddedDamageRatioIce3 = 31703,
    AddedDamageRatioElec1 = 31801,
    AddedDamageRatioElec3 = 31803,
    AddedDamageRatioEther1 = 31901,
    AddedDamageRatioEther3 = 31903,
    SkipDefDamageRatio1 = 32201,
    SkipDefDamageRatio3 = 32203,
    AddedDamageRatioWind1 = 32301,
    AddedDamageRatioWind3 = 32303,
    // --- custom
    // growth
    HpMaxGrowth = 99991110,
    AtkGrowth = 99991210,
    DefGrowth = 99991310,
    // advance
    HpMaxAdvance = 99991111,
    AtkAdvance = 99991211,
    DefAdvance = 99991311,
};

const Allocator = std.mem.Allocator;

const templates = Assets.templates;

const logic = @import("../logic.zig");
const Assets = @import("../Assets.zig");

const std = @import("std");
