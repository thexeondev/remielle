pub fn mutateWeapons(
    changes: logic.Changes.Subset(.{
        logic.Changes.Weapon,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.Weapon,
    }),
) !void {
    const weapon = properties.weapon;

    for (changes.weapons) |change| {
        const index = std.mem.findScalar(Weapon.Uid, weapon.uids[0..weapon.count], change.uid) orelse new: {
            defer weapon.count += 1;
            const i = weapon.count;
            weapon.uids[i] = change.uid;
            weapon.ids[i] = change.id;
            break :new i;
        };

        weapon.levels[index] = change.level;
        weapon.stars[index] = change.star;
        weapon.refines[index] = change.refine;
    }
}

pub fn mutateEquipment(
    changes: logic.Changes.Subset(.{
        logic.Changes.Equip,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.Equipment,
    }),
) !void {
    const equip = properties.equip;

    for (changes.equipment) |change| {
        const index = std.mem.findScalar(Equipment.Uid, equip.uids[0..equip.count], change.uid) orelse new: {
            defer equip.count += 1;
            const i = equip.count;
            equip.uids[i] = change.uid;
            equip.ids[i] = change.id;
            break :new i;
        };

        equip.levels[index] = change.level;
        equip.stars[index] = change.star;
        equip.properties[index] = change.properties;
    }
}

const Weapon = Properties.Weapon;
const Equipment = Properties.Equipment;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const mutators = @import("../mutators.zig");

const std = @import("std");
