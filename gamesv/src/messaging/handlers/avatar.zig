const remielle = @import("remielle");
const pb = remielle.protobuf.main;

pub fn getAvatarData(
    message: Message(pb.GetAvatarDataCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    response: Response(pb.GetAvatarDataScRsp),
) !void {
    _ = message;

    const count = properties.avatar.count();

    const metas = properties.avatar.meta[0..count];
    const weapon_uids = properties.avatar.weapon_uids[0..count];
    const equipment_uids = properties.avatar.equipment_uids[0..count];

    var infos: ArrayList(pb.AvatarInfo) = try .initCapacity(response.allocator, metas.len);

    for (metas, weapon_uids, equipment_uids, 0..) |*meta, weapon_uid, equipment, index|
        infos.appendAssumeCapacity(try packers.packAvatarInfo(
            response.allocator,
            properties.avatar.ids[index],
            meta,
            weapon_uid,
            equipment,
        ));

    response.set(.{ .avatar_list = infos });
}

pub fn avatarFavorite(
    message: Message(pb.AvatarFavoriteCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.AvatarFavoriteScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    var meta = properties.avatar.meta[index];

    if (meta.flags.favorite != message.data.is_favorite) {
        meta.flags.favorite = message.data.is_favorite;

        const avatars = try changes.allocator.alloc(Changes.Avatar, 1);

        avatars[0] = .{
            .id = properties.avatar.ids[index],
            .meta = meta,
            .weapon_uid = properties.avatar.weapon_uids[index],
            .equipment_uids = properties.avatar.equipment_uids[index],
            .awake_material_count = properties.avatar.awake_material_counts[index],
        };

        changes.insert(avatars);
    }

    response.set(.init);
}

pub fn avatarSkinDress(
    message: Message(pb.AvatarSkinDressCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
        Properties.BasicInfo,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
        Changes.ControlGuiseAvatar,
    }),
    response: Response(pb.AvatarSkinDressScRsp),
) !void {
    const new_skin = templates.avatar_skin_base.map.get(@enumFromInt(message.data.avatar_skin_id)) orelse
        return response.fail(1);

    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    if (new_skin.avatar_id != @intFromEnum(properties.avatar.ids[index]))
        return response.fail(1);

    var meta = properties.avatar.meta[index];

    if (meta.skin.toInt() != new_skin.id) {
        // TODO: check if it's unlocked.

        const avatars = try changes.allocator.alloc(Changes.Avatar, 1);

        meta.skin = @enumFromInt(new_skin.id);
        avatars[0] = .{
            .id = properties.avatar.ids[index],
            .meta = meta,
            .weapon_uid = properties.avatar.weapon_uids[index],
            .equipment_uids = properties.avatar.equipment_uids[index],
            .awake_material_count = properties.avatar.awake_material_counts[index],
        };

        changes.insert(avatars);

        if (properties.basic_info.control_guise_avatar.toInt() == new_skin.avatar_id)
            changes.insert(Changes.ControlGuiseAvatar{
                .guise = properties.basic_info.control_guise_avatar,
                .guise_skin = @enumFromInt(new_skin.id),
            });
    }

    response.set(.init);
}

pub fn avatarSkinUnDress(
    message: Message(pb.AvatarSkinUnDressCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
        Properties.BasicInfo,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
        Changes.ControlGuiseAvatar,
    }),
    response: Response(pb.AvatarSkinUnDressScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    var meta = properties.avatar.meta[index];

    if (meta.skin != .none) {
        meta.skin = .none;

        const avatars = try changes.allocator.alloc(Changes.Avatar, 1);

        avatars[0] = .{
            .id = properties.avatar.ids[index],
            .meta = meta,
            .weapon_uid = properties.avatar.weapon_uids[index],
            .equipment_uids = properties.avatar.equipment_uids[index],
            .awake_material_count = properties.avatar.awake_material_counts[index],
        };

        changes.insert(avatars);

        if (properties.basic_info.control_guise_avatar.toInt() == @intFromEnum(properties.avatar.ids[index]))
            changes.insert(Changes.ControlGuiseAvatar{
                .guise = properties.basic_info.control_guise_avatar,
                .guise_skin = .none,
            });
    }

    response.set(.init);
}

pub fn weaponDress(
    message: Message(pb.WeaponDressCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
        Properties.Weapon,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.WeaponDressScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    const weapon_uid = Properties.Weapon.Uid.fromInt(message.data.weapon_uid) orelse
        return response.fail(1);

    const weapon_index = std.mem.findScalar(
        Properties.Weapon.Uid,
        properties.weapon.uids[0..properties.weapon.count],
        weapon_uid,
    ) orelse return response.fail(1);

    var meta = properties.avatar.meta[index];

    if (meta.flags.show_weapon == .locked) {
        const template = templates.weapon.map.get(properties.weapon.ids[weapon_index]).?;
        if (template.avatar_id == @intFromEnum(properties.avatar.ids[index]))
            meta.flags.show_weapon = .enabled;
    }

    const avatars = try changes.allocator.alloc(Changes.Avatar, 2);

    avatars[0] = .{
        .id = properties.avatar.ids[index],
        .meta = meta,
        .weapon_uid = @enumFromInt(weapon_uid.toInt()),
        .equipment_uids = properties.avatar.equipment_uids[index],
        .awake_material_count = properties.avatar.awake_material_counts[index],
    };

    var changes_count: usize = 1;

    if (std.mem.findScalar(
        Avatar.OptionalUID,
        properties.avatar.weapon_uids[0..properties.avatar.count()],
        @enumFromInt(weapon_uid.toInt()),
    )) |prev_owner_index| {
        // Another avatar has this weapon equipped, swap them.
        changes_count = 2;

        avatars[1] = .{
            .id = properties.avatar.ids[prev_owner_index],
            .meta = properties.avatar.meta[prev_owner_index],
            .weapon_uid = properties.avatar.weapon_uids[index],
            .equipment_uids = properties.avatar.equipment_uids[prev_owner_index],
            .awake_material_count = properties.avatar.awake_material_counts[prev_owner_index],
        };
    }

    changes.insert(avatars[0..changes_count]);
    response.set(.init);
}

pub fn weaponUnDress(
    message: Message(pb.WeaponUnDressCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.WeaponUnDressScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    const avatars = try changes.allocator.alloc(Changes.Avatar, 1);

    avatars[0] = .{
        .id = properties.avatar.ids[index],
        .meta = properties.avatar.meta[index],
        .weapon_uid = .none, // undress
        .equipment_uids = properties.avatar.equipment_uids[index],
        .awake_material_count = properties.avatar.awake_material_counts[index],
    };

    changes.insert(avatars);
    response.set(.init);
}

pub fn equipmentDress(
    message: Message(pb.EquipmentDressCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.EquipmentDressScRsp),
) !void {
    const index: u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    } orelse return response.fail(1);

    const dress_index = Properties.Equipment.Slot.fromInt(message.data.dress_index) orelse
        return response.fail(1);

    const equip_uid = message.data.equip_uid;

    const avatars = try changes.allocator.alloc(Changes.Avatar, 2);

    var equipment_uids = properties.avatar.equipment_uids[index];

    const old_equip_id = equipment_uids[dress_index.toIndex()];
    equipment_uids[dress_index.toIndex()] = @enumFromInt(equip_uid);

    avatars[0] = .{
        .id = properties.avatar.ids[index],
        .meta = properties.avatar.meta[index],
        .weapon_uid = properties.avatar.weapon_uids[index],
        .equipment_uids = equipment_uids,
        .awake_material_count = properties.avatar.awake_material_counts[index],
    };

    var changes_count: usize = 1;

    const slots = Avatar.equipment_slots;

    const equipments = @as(
        [*]const Properties.Avatar.OptionalUID,
        @ptrCast(&properties.avatar.equipment_uids),
    )[0 .. properties.avatar.count() * slots];

    if (std.mem.findScalar(
        Properties.Avatar.OptionalUID,
        equipments,
        @enumFromInt(equip_uid),
    )) |prev_owner_index| {
        const avatar_idx = prev_owner_index / slots;
        const slot_idx = prev_owner_index % slots;

        changes_count = 2;

        var prev_owner_equipments_uids = properties.avatar.equipment_uids[avatar_idx];
        prev_owner_equipments_uids[slot_idx] = @enumFromInt(old_equip_id.unwrap() orelse 0);

        avatars[1] = .{
            .id = properties.avatar.ids[avatar_idx],
            .meta = properties.avatar.meta[avatar_idx],
            .weapon_uid = properties.avatar.weapon_uids[avatar_idx],
            .equipment_uids = prev_owner_equipments_uids,
            .awake_material_count = properties.avatar.awake_material_counts[avatar_idx],
        };
    }

    changes.insert(avatars[0..changes_count]);
    response.set(.init);
}

pub fn equipmentSuitDress(
    message: Message(pb.EquipmentSuitDressCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
        Properties.Equipment,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.EquipmentSuitDressScRsp),
) !void {
    const index: u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    } orelse return response.fail(1);

    const params = message.data.param_list.items;

    switch (params.len) {
        1...Properties.Avatar.equipment_slots => {},
        else => return response.fail(1),
    }

    const equipments = @as(
        [*]const Properties.Avatar.OptionalUID,
        @ptrCast(&properties.avatar.equipment_uids),
    )[0 .. properties.avatar.count() * Avatar.equipment_slots];

    const avatars = try changes.allocator.alloc(Changes.Avatar, 1);

    avatars[0] = .{
        .id = properties.avatar.ids[index],
        .meta = properties.avatar.meta[index],
        .weapon_uid = properties.avatar.weapon_uids[index],
        .equipment_uids = properties.avatar.equipment_uids[index],
        .awake_material_count = properties.avatar.awake_material_counts[index],
    };

    for (params) |param| {
        const slot = Properties.Equipment.Slot.fromInt(param.dress_index) orelse
            return response.fail(1);

        const uid = Properties.Equipment.Uid.fromInt(param.equip_uid) orelse
            return response.fail(1);

        if (std.mem.findScalar(Properties.Equipment.Uid, &properties.equip.uids, uid) == null)
            return response.fail(1);

        if (std.mem.findScalar(
            Properties.Avatar.OptionalUID,
            equipments,
            @enumFromInt(param.equip_uid),
        ) != null)
            return response.fail(1); // EquipmentSuitDressCsReq requests only unused equipment.

        avatars[0].equipment_uids[slot.toIndex()] = @enumFromInt(param.equip_uid);
    }

    changes.insert(avatars);
    response.set(.init);
}

pub fn equipmentUnDress(
    message: Message(pb.EquipmentUnDressCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.EquipmentUnDressScRsp),
) !void {
    const index: u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    } orelse return response.fail(1);

    const avatars = try changes.allocator.alloc(Changes.Avatar, 1);

    var equipment_uids = properties.avatar.equipment_uids[index];

    for (message.data.undress_index_list.items) |dress_i| {
        const dress_index = Properties.Equipment.Slot.fromInt(dress_i) orelse
            return response.fail(1);

        equipment_uids[dress_index.toIndex()] = .none;
    }

    avatars[0] = .{
        .id = properties.avatar.ids[index],
        .meta = properties.avatar.meta[index],
        .weapon_uid = properties.avatar.weapon_uids[index],
        .equipment_uids = equipment_uids,
        .awake_material_count = properties.avatar.awake_material_counts[index],
    };

    changes.insert(avatars);
    response.set(.init);
}

pub fn avatarUnlockAwake(
    message: Message(pb.AvatarUnlockAwakeCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.AvatarUnlockAwakeScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    const avatar_awake_material_count = properties.avatar.awake_material_counts[index];
    if (avatar_awake_material_count == .none or avatar_awake_material_count.toInt() == 0) {
        return response.fail(1);
    }

    var meta = properties.avatar.meta[index];

    for (templates.avatar_special_awaken.entries) |template| if (template.avatar_id == message.data.avatar_id) {
        if (template.id > meta.awakening.toInt()) {
            if (meta.awakening == .none) {
                meta.flags.awake_available = true;
                meta.flags.awake_enabled = true;
            }
            meta.awakening = @enumFromInt(template.id);

            const avatars = try changes.allocator.alloc(Changes.Avatar, 1);
            avatars[0] = .{
                .id = properties.avatar.ids[index],
                .meta = meta,
                .weapon_uid = properties.avatar.weapon_uids[index],
                .equipment_uids = properties.avatar.equipment_uids[index],
                .awake_material_count = @enumFromInt(avatar_awake_material_count.toInt() - 1),
            };

            changes.insert(avatars);
            break;
        }
    };

    if (meta.awakening == .none) {
        return response.fail(1);
    }

    response.set(.init);
}

pub fn avatarSetAwake(
    message: Message(pb.AvatarSetAwakeCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.AvatarSetAwakeScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    var meta = properties.avatar.meta[index];
    if (meta.awakening == .none) {
        return response.fail(1);
    }

    if (meta.flags.awake_enabled != message.data.is_awake_enabled) {
        meta.flags.awake_enabled = message.data.is_awake_enabled;

        const avatars = try changes.allocator.alloc(Changes.Avatar, 1);
        avatars[0] = .{
            .id = properties.avatar.ids[index],
            .meta = meta,
            .weapon_uid = properties.avatar.weapon_uids[index],
            .equipment_uids = properties.avatar.equipment_uids[index],
            .awake_material_count = properties.avatar.awake_material_counts[index],
        };
        changes.insert(avatars);
    }

    response.set(.init);
}

pub fn mindscapeChangeTabState(
    message: Message(pb.MindscapeChangeTabStateCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.MindscapeChangeTabStateScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    const tab_state = Properties.Avatar.MindscapeTabState.fromBools(
        message.data.mindscape_tab_state.items,
    ) orelse
        return response.fail(1);

    var meta = properties.avatar.meta[index];

    if (meta.talents.toInt() < tab_state.requiredTalentNum())
        return response.fail(1);

    if (meta.mindscape_tab_state != tab_state) {
        meta.mindscape_tab_state = tab_state;

        const avatars = try changes.allocator.alloc(Changes.Avatar, 1);
        avatars[0] = .{
            .id = properties.avatar.ids[index],
            .meta = meta,
            .weapon_uid = properties.avatar.weapon_uids[index],
            .equipment_uids = properties.avatar.equipment_uids[index],
            .awake_material_count = properties.avatar.awake_material_counts[index],
        };
        changes.insert(avatars);
    }

    response.set(.init);
}

pub fn avatarShowWeaponToggle(
    message: Message(pb.AvatarShowWeaponToggleCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    changes: Changes.Builder(.{
        Changes.Avatar,
    }),
    response: Response(pb.AvatarShowWeaponToggleScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    var meta = properties.avatar.meta[index];

    if (!meta.flags.show_weapon.isUnlocked())
        return response.fail(1);

    const show_weapon: Avatar.Flags.ShowWeapon = switch (message.data.show_weapon_type orelse .LOCKED) {
        .LOCKED => return response.fail(1), // the sense is not being made.
        .SHOW => .enabled,
        .HIDE => .disabled,
    };

    if (meta.flags.show_weapon != show_weapon) {
        meta.flags.show_weapon = show_weapon;

        const avatars = try changes.allocator.alloc(Changes.Avatar, 1);
        avatars[0] = .{
            .id = properties.avatar.ids[index],
            .meta = meta,
            .weapon_uid = properties.avatar.weapon_uids[index],
            .equipment_uids = properties.avatar.equipment_uids[index],
            .awake_material_count = properties.avatar.awake_material_counts[index],
        };
        changes.insert(avatars);
    }

    response.set(.init);
}

const Avatar = Properties.Avatar;
const ArrayList = std.ArrayList;
const templates = Assets.templates;

const Changes = logic.Changes;
const Properties = logic.Properties;

const Message = handlers.Message;
const Response = handlers.Response;

const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const std = @import("std");
