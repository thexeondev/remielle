const std = @import("std");
const ArrayList = std.ArrayList;

const packers = @import("../../messaging/packers.zig");
const logic = @import("../../logic.zig");
const handlers = @import("../handlers.zig");

const Scope = handlers.Scope;
const Properties = logic.Properties;

const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

pub fn GetWeaponDataCsReq(scope: *Scope) !void {
    var weapon_list: ArrayList(pb.WeaponInfo) = try .initCapacity(
        scope.sink.allocator,
        scope.properties.weapon.count,
    );

    var i: u16 = 0;
    while (i < scope.properties.weapon.count) : (i += 1) {
        weapon_list.appendAssumeCapacity(.{
            .uid = scope.properties.weapon.uids[i].toInt(),
            .id = @backingInt(scope.properties.weapon.ids[i]),
            .level = scope.properties.weapon.levels[i].toInt(),
            .star = scope.properties.weapon.stars[i].toInt(),
            .refine_level = scope.properties.weapon.refines[i].toInt(),
        });
    }

    try scope.sink.respond(pb.GetWeaponDataScRsp, .{ .weapon_list = weapon_list });
}

pub fn GetEquipDataCsReq(scope: *Scope) !void {
    var equip_list: ArrayList(pb.EquipInfo) = try .initCapacity(
        scope.sink.allocator,
        scope.properties.equip.count,
    );

    var i: u16 = 0;
    while (i < scope.properties.equip.count) : (i += 1) {
        equip_list.appendAssumeCapacity(try packers.packEquipmentInfo(
            scope.sink.allocator,
            scope.properties.equip.uids[i],
            scope.properties.equip.ids[i],
            scope.properties.equip.levels[i],
            scope.properties.equip.stars[i],
            &scope.properties.equip.properties[i],
        ));
    }

    try scope.sink.respond(pb.GetEquipDataScRsp, .{ .equip_list = equip_list });
}

pub fn GetItemDataCsReq(scope: *Scope) !void {
    var materials: std.ArrayList(pb.MaterialInfo) = try .initCapacity(
        scope.sink.allocator,
        // TODO: upper bound must include awake materials
        templates.avatar_skin_base.entries.len,
    );

    for (templates.avatar_skin_base.entries) |entry|
        materials.appendAssumeCapacity(.{ .id = entry.id, .count = 1 });

    const avatar_count = scope.properties.avatar.count();
    const awake_material_counts = scope.properties.avatar.awake_material_counts[0..avatar_count];
    for (awake_material_counts, 0..) |awake_material_count, index| {
        if (awake_material_count != .none) {
            try materials.append(scope.sink.allocator, .{
                .id = 20_000 + @divFloor(@backingInt(scope.properties.avatar.ids[index]), 10),
                .count = awake_material_count.toInt(),
            });
        }
    }

    try scope.sink.respond(pb.GetItemDataScRsp, .{ .material_list = materials });
}

pub fn GetWishlistDataCsReq(scope: *Scope) !void {
    try scope.sink.respond(pb.GetWishlistDataScRsp, .init);
}
