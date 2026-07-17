const remielle = @import("remielle");
const pb = remielle.protobuf.main;

pub fn getWeaponData(
    message: Message(pb.GetWeaponDataCsReq),
    properties: Properties.Immutable(.{
        Properties.Weapon,
    }),
    response: Response(pb.GetWeaponDataScRsp),
) !void {
    _ = message;

    var weapon_list: ArrayList(pb.WeaponInfo) = try .initCapacity(
        response.allocator,
        properties.weapon.count,
    );

    var i: u16 = 0;

    while (i < properties.weapon.count) : (i += 1) {
        weapon_list.appendAssumeCapacity(.{
            .uid = properties.weapon.uids[i].toInt(),
            .id = @intFromEnum(properties.weapon.ids[i]),
            .level = properties.weapon.levels[i].toInt(),
            .star = properties.weapon.stars[i].toInt(),
            .refine_level = properties.weapon.refines[i].toInt(),
        });
    }

    response.set(.{ .weapon_list = weapon_list });
}

pub fn getEquipData(
    message: Message(pb.GetEquipDataCsReq),
    properties: Properties.Immutable(.{
        Properties.Equipment,
    }),
    response: Response(pb.GetEquipDataScRsp),
) !void {
    _ = message;

    var equip_list: ArrayList(pb.EquipInfo) = try .initCapacity(response.allocator, properties.equip.count);

    var i: u16 = 0;

    while (i < properties.equip.count) : (i += 1) {
        equip_list.appendAssumeCapacity(try packers.packEquipmentInfo(
            response.allocator,
            properties.equip.uids[i],
            properties.equip.ids[i],
            properties.equip.levels[i],
            properties.equip.stars[i],
            &properties.equip.properties[i],
        ));
    }

    response.set(.{ .equip_list = equip_list });
}

pub fn getItemData(
    message: Message(pb.GetItemDataCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    response: Response(pb.GetItemDataScRsp),
) !void {
    _ = message;

    var materials: std.ArrayList(pb.MaterialInfo) = try .initCapacity(
        response.allocator,
        templates.avatar_skin_base.entries.len,
    );

    for (templates.avatar_skin_base.entries) |entry|
        materials.appendAssumeCapacity(.{ .id = entry.id, .count = 1 });

    const avatar_count = properties.avatar.count();
    const awake_material_counts = properties.avatar.awake_material_counts[0..avatar_count];
    for (awake_material_counts, 0..) |awake_material_count, index| if (awake_material_count != .none) {
        try materials.append(response.allocator, .{
            .id = 20_000 + @divFloor(@intFromEnum(properties.avatar.ids[index]), 10),
            .count = awake_material_count.toInt(),
        });
    };

    response.set(.{
        .material_list = materials,
    });
}

pub fn getWishlistData(
    message: Message(pb.GetWishlistDataCsReq),
    response: Response(pb.GetWishlistDataScRsp),
) !void {
    _ = message;
    response.set(.init);
}

const templates = Assets.templates;

const ArrayList = std.ArrayList;
const Message = handlers.Message;
const Response = handlers.Response;
const Properties = logic.Properties;

const packers = @import("../../messaging/packers.zig");
const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const std = @import("std");
