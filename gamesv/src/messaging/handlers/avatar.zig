const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

pub fn getAvatarData(
    message: Message(pb.GetAvatarDataCsReq),
    properties: Properties.Immutable(.{
        Properties.Avatar,
    }),
    response: Response(pb.GetAvatarDataScRsp),
) !void {
    _ = message;

    const count = properties.avatar.count();
    var infos: ArrayList(pb.AvatarInfo) = try .initCapacity(response.allocator, count);

    var index: u32 = 0;
    while (index < count) : (index += 1) {
        infos.appendAssumeCapacity(try packers.packAvatarInfo(
            response.allocator,
            properties.avatar,
            index,
        ));
    }

    response.set(.{ .avatar_list = infos });
}

pub fn avatarFavorite(
    message: Message(pb.AvatarFavoriteCsReq),
    properties: Properties.Mutable(.{
        Properties.Avatar,
    }),
    sink: Sink,
    response: Response(pb.AvatarFavoriteScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    const meta = &properties.avatar.meta[index];

    if (meta.flags.favorite != message.data.is_favorite) {
        meta.flags.favorite = message.data.is_favorite;

        var info: pb.AvatarInfo = try packers.packAvatarInfo(
            response.allocator,
            properties.avatar,
            index,
        );

        try sink.notify(pb.PlayerSyncScNotify, .{
            .avatar = .{ .avatar_list = .fromOwnedSlice((&info)[0..1]) },
        });
    }

    response.set(.init);
}

pub fn avatarSkinDress(
    message: Message(pb.AvatarSkinDressCsReq),
    properties: Properties.Mutable(.{
        Properties.Avatar,
        Properties.BasicInfo,
    }),
    sink: Sink,
    response: Response(pb.AvatarSkinDressScRsp),
) !void {
    const new_skin = templates.avatar_skin_base.map.get(@fromBackingInt(@intCast(message.data.avatar_skin_id))) orelse
        return response.fail(1);

    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    if (new_skin.avatar_id != @backingInt(properties.avatar.ids[index]))
        return response.fail(1);

    const meta = &properties.avatar.meta[index];

    if (meta.skin.toInt() != new_skin.id) {
        // TODO: check if it's unlocked.
        meta.skin = @fromBackingInt(@intCast(new_skin.id));

        var info: pb.AvatarInfo = try packers.packAvatarInfo(
            response.allocator,
            properties.avatar,
            index,
        );

        var notify: pb.PlayerSyncScNotify = .{
            .avatar = .{ .avatar_list = .fromOwnedSlice((&info)[0..1]) },
        };

        if (properties.basic_info.control_guise_avatar.toInt() == new_skin.avatar_id) {
            properties.basic_info.control_guise_avatar_skin = @fromBackingInt(new_skin.id);

            notify.misc = .{
                .player_accessory = .{
                    .control_guise_avatar_id = properties.basic_info.control_guise_avatar.toInt(),
                    .control_guise_avatar_skin_id = new_skin.id,
                },
            };
        }

        try sink.notify(pb.PlayerSyncScNotify, notify);
    }

    response.set(.init);
}

pub fn avatarSkinUnDress(
    message: Message(pb.AvatarSkinUnDressCsReq),
    properties: Properties.Mutable(.{
        Properties.Avatar,
        Properties.BasicInfo,
    }),
    sink: Sink,
    response: Response(pb.AvatarSkinUnDressScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    const meta = &properties.avatar.meta[index];

    if (meta.skin != .none) {
        meta.skin = .none;

        var info: pb.AvatarInfo = try packers.packAvatarInfo(
            response.allocator,
            properties.avatar,
            index,
        );

        var notify: pb.PlayerSyncScNotify = .{
            .avatar = .{ .avatar_list = .fromOwnedSlice((&info)[0..1]) },
        };

        if (properties.basic_info.control_guise_avatar.toInt() == @backingInt(properties.avatar.ids[index])) {
            properties.basic_info.control_guise_avatar_skin = .none;

            notify.misc = .{
                .player_accessory = .{
                    .control_guise_avatar_id = properties.basic_info.control_guise_avatar.toInt(),
                    .control_guise_avatar_skin_id = 0,
                },
            };
        }

        try sink.notify(pb.PlayerSyncScNotify, notify);
    }

    response.set(.init);
}

pub fn weaponDress(
    message: Message(pb.WeaponDressCsReq),
    properties: Properties.Mutable(.{
        Properties.Avatar,
        Properties.Weapon,
    }),
    sink: Sink,
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

    const meta = &properties.avatar.meta[index];

    if (meta.flags.show_weapon == .locked) {
        const template = templates.weapon.map.get(properties.weapon.ids[weapon_index]).?;
        if (template.avatar_id == @backingInt(properties.avatar.ids[index]))
            meta.flags.show_weapon = .enabled;
    }

    var avatars: ArrayList(pb.AvatarInfo) = try .initCapacity(response.allocator, 2);

    if (std.mem.findScalar(
        Avatar.OptionalUID,
        properties.avatar.weapon_uids[0..properties.avatar.count()],
        @fromBackingInt(@intCast(weapon_uid.toInt())),
    )) |prev_owner_index| {
        // Another avatar has this weapon equipped, swap them.
        properties.avatar.weapon_uids[prev_owner_index] =
            properties.avatar.weapon_uids[index];

        avatars.appendAssumeCapacity(try packers.packAvatarInfo(
            response.allocator,
            properties.avatar,
            prev_owner_index,
        ));
    }

    properties.avatar.weapon_uids[index] = @fromBackingInt(weapon_uid.toInt());

    avatars.appendAssumeCapacity(try packers.packAvatarInfo(
        response.allocator,
        properties.avatar,
        index,
    ));

    try sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = avatars },
    });

    response.set(.init);
}

pub fn weaponUnDress(
    message: Message(pb.WeaponUnDressCsReq),
    properties: Properties.Mutable(.{
        Properties.Avatar,
    }),
    sink: Sink,
    response: Response(pb.WeaponUnDressScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    properties.avatar.weapon_uids[index] = .none;

    var info: pb.AvatarInfo = try packers.packAvatarInfo(
        response.allocator,
        properties.avatar,
        index,
    );

    try sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&info)[0..1]) },
    });

    response.set(.init);
}

pub fn equipmentDress(
    message: Message(pb.EquipmentDressCsReq),
    properties: Properties.Mutable(.{
        Properties.Avatar,
    }),
    sink: Sink,
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

    var avatars: ArrayList(pb.AvatarInfo) = try .initCapacity(response.allocator, 2);

    var equipment_uids = properties.avatar.equipment_uids[index];

    const old_equip_id = equipment_uids[dress_index.toIndex()];
    equipment_uids[dress_index.toIndex()] = @fromBackingInt(@intCast(equip_uid));

    const slots = Avatar.equipment_slots;

    const equipments = @as(
        [*]const Properties.Avatar.OptionalUID,
        @ptrCast(&properties.avatar.equipment_uids),
    )[0 .. properties.avatar.count() * slots];

    if (std.mem.findScalar(
        Properties.Avatar.OptionalUID,
        equipments,
        @fromBackingInt(@intCast(equip_uid)),
    )) |prev_owner_index| {
        const avatar_idx = prev_owner_index / slots;
        const slot_idx = prev_owner_index % slots;

        var prev_owner_equipments_uids = properties.avatar.equipment_uids[avatar_idx];
        prev_owner_equipments_uids[slot_idx] =
            @fromBackingInt(@intCast(old_equip_id.unwrap() orelse 0));

        properties.avatar.equipment_uids[prev_owner_index] = prev_owner_equipments_uids;

        avatars.appendAssumeCapacity(try packers.packAvatarInfo(
            response.allocator,
            properties.avatar,
            prev_owner_index,
        ));
    }

    properties.avatar.equipment_uids[index] = equipment_uids;

    avatars.appendAssumeCapacity(try packers.packAvatarInfo(
        response.allocator,
        properties.avatar,
        index,
    ));

    try sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = avatars },
    });

    response.set(.init);
}

pub fn equipmentSuitDress(
    message: Message(pb.EquipmentSuitDressCsReq),
    response: Response(pb.EquipmentSuitDressScRsp),
) !void {
    // TODO: reimplement once `Changes` is removed.
    _ = message;
    response.set(.init);
}

pub fn equipmentUnDress(
    message: Message(pb.EquipmentUnDressCsReq),
    properties: Properties.Mutable(.{
        Properties.Avatar,
    }),
    sink: Sink,
    response: Response(pb.EquipmentUnDressScRsp),
) !void {
    const index: u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    } orelse return response.fail(1);

    var equipment_uids = properties.avatar.equipment_uids[index];

    for (message.data.undress_index_list.items) |dress_i| {
        const dress_index = Properties.Equipment.Slot.fromInt(dress_i) orelse
            return response.fail(1);

        equipment_uids[dress_index.toIndex()] = .none;
    }

    properties.avatar.equipment_uids[index] = equipment_uids;

    var info: pb.AvatarInfo = try packers.packAvatarInfo(
        response.allocator,
        properties.avatar,
        index,
    );

    try sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&info)[0..1]) },
    });

    response.set(.init);
}

pub fn avatarUnlockAwake(
    message: Message(pb.AvatarUnlockAwakeCsReq),
    properties: Properties.Mutable(.{
        Properties.Avatar,
    }),
    sink: Sink,
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

    const meta = &properties.avatar.meta[index];

    for (templates.avatar_special_awaken.entries) |template| {
        if (template.avatar_id == message.data.avatar_id) {
            if (template.id > meta.awakening.toInt()) {
                if (meta.awakening == .none) {
                    meta.flags.awake_available = true;
                    meta.flags.awake_enabled = true;
                }
                meta.awakening = @fromBackingInt(@intCast(template.id));

                properties.avatar.awake_material_counts[index] = @fromBackingInt(
                    avatar_awake_material_count.toInt() - 1,
                );

                break;
            }
        }
    } else {
        return response.fail(1);
    }

    var avatar_info: pb.AvatarInfo = try packers.packAvatarInfo(
        response.allocator,
        properties.avatar,
        index,
    );

    var material_info: pb.MaterialInfo = .{
        .id = 20_000 + @divFloor(message.data.avatar_id, 10),
        .count = properties.avatar.awake_material_counts[index].toInt(),
    };

    try sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&avatar_info)[0..1]) },
        .item = .{ .material_list = .fromOwnedSlice((&material_info)[0..1]) },
    });

    response.set(.init);
}

pub fn avatarSetAwake(
    message: Message(pb.AvatarSetAwakeCsReq),
    properties: Properties.Mutable(.{
        Properties.Avatar,
    }),
    sink: Sink,
    response: Response(pb.AvatarSetAwakeScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    var meta = &properties.avatar.meta[index];
    if (meta.awakening == .none) {
        return response.fail(1);
    }

    if (meta.flags.awake_enabled != message.data.is_awake_enabled) {
        meta.flags.awake_enabled = message.data.is_awake_enabled;

        var avatar_info: pb.AvatarInfo = try packers.packAvatarInfo(
            response.allocator,
            properties.avatar,
            index,
        );

        try sink.notify(pb.PlayerSyncScNotify, .{
            .avatar = .{ .avatar_list = .fromOwnedSlice((&avatar_info)[0..1]) },
        });
    }

    response.set(.init);
}

pub fn mindscapeChangeTabState(
    message: Message(pb.MindscapeChangeTabStateCsReq),
    properties: Properties.Mutable(.{
        Properties.Avatar,
    }),
    sink: Sink,
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

    const meta = &properties.avatar.meta[index];

    if (meta.talents.toInt() < tab_state.requiredTalentNum())
        return response.fail(1);

    if (meta.mindscape_tab_state != tab_state) {
        meta.mindscape_tab_state = tab_state;

        var avatar_info: pb.AvatarInfo = try packers.packAvatarInfo(
            response.allocator,
            properties.avatar,
            index,
        );

        try sink.notify(pb.PlayerSyncScNotify, .{
            .avatar = .{ .avatar_list = .fromOwnedSlice((&avatar_info)[0..1]) },
        });
    }

    response.set(.init);
}

pub fn avatarShowWeaponToggle(
    message: Message(pb.AvatarShowWeaponToggleCsReq),
    properties: Properties.Mutable(.{
        Properties.Avatar,
    }),
    sink: Sink,
    response: Response(pb.AvatarShowWeaponToggleScRsp),
) !void {
    const maybe_index: ?u32 = avatar_index: {
        const id = std.enums.fromInt(Properties.Avatar.Id, message.data.avatar_id) orelse
            break :avatar_index null;

        break :avatar_index properties.avatar.indexes.get(id);
    };

    const index = maybe_index orelse
        return response.fail(1);

    const meta = &properties.avatar.meta[index];

    if (!meta.flags.show_weapon.isUnlocked())
        return response.fail(1);

    const show_weapon: Avatar.Flags.ShowWeapon = switch (message.data.show_weapon_type orelse .LOCKED) {
        .LOCKED => return response.fail(1), // the sense is not being made.
        .SHOW => .enabled,
        .HIDE => .disabled,
    };

    if (meta.flags.show_weapon != show_weapon) {
        meta.flags.show_weapon = show_weapon;

        var avatar_info: pb.AvatarInfo = try packers.packAvatarInfo(
            response.allocator,
            properties.avatar,
            index,
        );

        try sink.notify(pb.PlayerSyncScNotify, .{
            .avatar = .{ .avatar_list = .fromOwnedSlice((&avatar_info)[0..1]) },
        });
    }

    response.set(.init);
}

const Avatar = Properties.Avatar;
const ArrayList = std.ArrayList;

const Changes = logic.Changes;
const Properties = logic.Properties;

const Sink = handlers.Sink;
const Message = handlers.Message;
const Response = handlers.Response;

const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const handlers = @import("../handlers.zig");

const std = @import("std");
