const std = @import("std");
const ArrayList = std.ArrayList;

const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

const logic = @import("../../logic.zig");
const Properties = logic.Properties;
const Avatar = logic.Properties.Avatar;

const handlers = @import("../handlers.zig");
const Scope = handlers.Scope;

const packers = @import("../packers.zig");

pub fn GetAvatarDataCsReq(scope: *Scope) !void {
    var avatar_list_buffer: [Properties.Avatar.size]pb.AvatarInfo = undefined;
    var avatar_list: ArrayList(pb.AvatarInfo) = .initBuffer(&avatar_list_buffer);

    const count = scope.properties.avatar.count();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        avatar_list.appendAssumeCapacity(try packers.packAvatarInfo(
            scope.sink.allocator,
            &scope.properties.avatar,
            index,
        ));
    }

    try scope.sink.respond(pb.GetAvatarDataScRsp, .{ .avatar_list = avatar_list });
}

fn getIndexById(scope: *Scope, avatar_id: u32) ?u32 {
    const id = std.enums.fromInt(Properties.Avatar.Id, avatar_id) orelse
        return null;

    return scope.properties.avatar.indexes.get(id);
}

pub fn AvatarFavoriteCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.AvatarFavoriteCsReq);

    const index = getIndexById(scope, request.avatar_id) orelse
        return try scope.sink.respond(pb.AvatarFavoriteScRsp, .{ .retcode = 1 });

    scope.properties.avatar.meta[index].flags.favorite = request.is_favorite;

    var info: pb.AvatarInfo = try packers.packAvatarInfo(
        scope.sink.allocator,
        &scope.properties.avatar,
        index,
    );

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&info)[0..1]) },
    });

    try scope.sink.respond(pb.AvatarFavoriteScRsp, .init);
}

pub fn AvatarSkinDressCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.AvatarSkinDressCsReq);

    const index = getIndexById(scope, request.avatar_id) orelse
        return try scope.sink.respond(pb.AvatarSkinDressScRsp, .{ .retcode = 1 });

    const new_skin = templates.avatar_skin_base.map.get(@fromBackingInt(request.avatar_skin_id)) orelse
        return try scope.sink.respond(pb.AvatarSkinDressScRsp, .{ .retcode = 1 });

    if (new_skin.avatar_id != @backingInt(scope.properties.avatar.ids[index]))
        return try scope.sink.respond(pb.AvatarSkinDressScRsp, .{ .retcode = 1 });

    // TODO: check if it's unlocked.

    scope.properties.avatar.meta[index].skin = @fromBackingInt(new_skin.id);

    var info: pb.AvatarInfo = try packers.packAvatarInfo(
        scope.sink.allocator,
        &scope.properties.avatar,
        index,
    );

    var notify: pb.PlayerSyncScNotify = .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&info)[0..1]) },
    };

    if (scope.properties.basic_info.control_guise_avatar.toInt() ==
        new_skin.avatar_id)
    {
        scope.properties.basic_info.control_guise_avatar_skin = @fromBackingInt(new_skin.id);

        notify.misc = .{
            .player_accessory = .{
                .control_guise_avatar_id = scope.properties.basic_info.control_guise_avatar.toInt(),
                .control_guise_avatar_skin_id = new_skin.id,
            },
        };
    }

    try scope.sink.notify(pb.PlayerSyncScNotify, notify);

    try scope.sink.respond(pb.AvatarSkinDressScRsp, .init);
}

pub fn AvatarSkinUnDressCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.AvatarSkinUnDressCsReq);

    const index = getIndexById(scope, request.avatar_id) orelse
        return try scope.sink.respond(pb.AvatarSkinUnDressScRsp, .{ .retcode = 1 });

    scope.properties.avatar.meta[index].skin = .none;

    var info: pb.AvatarInfo = try packers.packAvatarInfo(
        scope.sink.allocator,
        &scope.properties.avatar,
        index,
    );

    var notify: pb.PlayerSyncScNotify = .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&info)[0..1]) },
    };

    if (scope.properties.basic_info.control_guise_avatar.toInt() ==
        @backingInt(scope.properties.avatar.ids[index]))
    {
        scope.properties.basic_info.control_guise_avatar_skin = .none;

        notify.misc = .{
            .player_accessory = .{
                .control_guise_avatar_id = scope.properties.basic_info.control_guise_avatar.toInt(),
                .control_guise_avatar_skin_id = 0,
            },
        };
    }

    try scope.sink.notify(pb.PlayerSyncScNotify, notify);
    try scope.sink.respond(pb.AvatarSkinUnDressScRsp, .init);
}

pub fn WeaponDressCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.WeaponDressCsReq);

    const index = getIndexById(scope, request.avatar_id) orelse
        return try scope.sink.respond(pb.WeaponDressScRsp, .{ .retcode = 1 });

    const weapon_uid = Properties.Weapon.Uid.fromInt(request.weapon_uid) orelse
        return try scope.sink.respond(pb.WeaponDressScRsp, .{ .retcode = 1 });

    const weapon_index = std.mem.findScalar(
        Properties.Weapon.Uid,
        scope.properties.weapon.uids[0..scope.properties.weapon.count],
        weapon_uid,
    ) orelse return try scope.sink.respond(pb.WeaponDressScRsp, .{ .retcode = 1 });

    const meta = &scope.properties.avatar.meta[index];

    if (meta.flags.show_weapon == .locked) {
        const template = templates.weapon.map.get(scope.properties.weapon.ids[weapon_index]).?;
        if (template.avatar_id == @backingInt(scope.properties.avatar.ids[index]))
            meta.flags.show_weapon = .enabled;
    }

    var avatars_buffer: [2]pb.AvatarInfo = undefined;
    var avatars: ArrayList(pb.AvatarInfo) = .initBuffer(&avatars_buffer);

    if (std.mem.findScalar(
        Avatar.OptionalUID,
        scope.properties.avatar.weapon_uids[0..scope.properties.avatar.count()],
        @fromBackingInt(@intCast(weapon_uid.toInt())),
    )) |prev_owner_index| {
        // Another avatar has this weapon equipped, swap them.
        scope.properties.avatar.weapon_uids[prev_owner_index] =
            scope.properties.avatar.weapon_uids[index];

        avatars.appendAssumeCapacity(try packers.packAvatarInfo(
            scope.sink.allocator,
            &scope.properties.avatar,
            prev_owner_index,
        ));
    }

    scope.properties.avatar.weapon_uids[index] = @fromBackingInt(weapon_uid.toInt());

    avatars.appendAssumeCapacity(try packers.packAvatarInfo(
        scope.sink.allocator,
        &scope.properties.avatar,
        index,
    ));

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = avatars },
    });

    try scope.sink.respond(pb.WeaponDressScRsp, .init);
}

pub fn WeaponUnDressCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.WeaponUnDressCsReq);

    const index = getIndexById(scope, request.avatar_id) orelse
        return try scope.sink.respond(pb.WeaponUnDressScRsp, .{ .retcode = 1 });

    scope.properties.avatar.weapon_uids[index] = .none;

    var info: pb.AvatarInfo = try packers.packAvatarInfo(
        scope.sink.allocator,
        &scope.properties.avatar,
        index,
    );

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&info)[0..1]) },
    });

    try scope.sink.respond(pb.WeaponUnDressScRsp, .init);
}

pub fn EquipmentDressCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.EquipmentDressCsReq);

    const index = getIndexById(scope, request.avatar_id) orelse
        return try scope.sink.respond(pb.WeaponUnDressScRsp, .{ .retcode = 1 });

    const dress_index = Properties.Equipment.Slot.fromInt(request.dress_index) orelse
        return try scope.sink.respond(pb.EquipmentDressScRsp, .{ .retcode = 1 });

    const equip_uid = request.equip_uid;

    var avatars_buffer: [2]pb.AvatarInfo = undefined;
    var avatars: ArrayList(pb.AvatarInfo) = .initBuffer(&avatars_buffer);

    var equipment_uids = scope.properties.avatar.equipment_uids[index];

    const old_equip_id = equipment_uids[dress_index.toIndex()];
    equipment_uids[dress_index.toIndex()] = @fromBackingInt(@intCast(equip_uid));

    const slots = Avatar.equipment_slots;

    const equipments = @as(
        [*]const Properties.Avatar.OptionalUID,
        @ptrCast(&scope.properties.avatar.equipment_uids),
    )[0 .. scope.properties.avatar.count() * slots];

    if (std.mem.findScalar(
        Properties.Avatar.OptionalUID,
        equipments,
        @fromBackingInt(@intCast(equip_uid)),
    )) |prev_owner_index| {
        const avatar_idx = prev_owner_index / slots;
        const slot_idx = prev_owner_index % slots;

        var prev_owner_equipments_uids = scope.properties.avatar.equipment_uids[avatar_idx];
        prev_owner_equipments_uids[slot_idx] =
            @fromBackingInt(@intCast(old_equip_id.unwrap() orelse 0));

        scope.properties.avatar.equipment_uids[prev_owner_index] =
            prev_owner_equipments_uids;

        avatars.appendAssumeCapacity(try packers.packAvatarInfo(
            scope.sink.allocator,
            &scope.properties.avatar,
            prev_owner_index,
        ));
    }

    scope.properties.avatar.equipment_uids[index] = equipment_uids;

    avatars.appendAssumeCapacity(try packers.packAvatarInfo(
        scope.sink.allocator,
        &scope.properties.avatar,
        index,
    ));

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = avatars },
    });

    try scope.sink.respond(pb.EquipmentDressScRsp, .init);
}

pub fn EquipmentSuitDressCsReq(scope: *Scope) !void {
    // TODO: reimplement once `Changes` is removed.
    try scope.sink.respond(pb.EquipmentSuitDressScRsp, .init);
}

pub fn EquipmentUnDressCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.EquipmentUnDressCsReq);

    const index: u32 = getIndexById(scope, request.avatar_id) orelse
        return try scope.sink.respond(pb.EquipmentUnDressScRsp, .{ .retcode = 1 });

    var equipment_uids = scope.properties.avatar.equipment_uids[index];

    for (request.undress_index_list.items) |dress_i| {
        const dress_index = Properties.Equipment.Slot.fromInt(dress_i) orelse
            return try scope.sink.respond(pb.EquipmentUnDressScRsp, .{ .retcode = 1 });

        equipment_uids[dress_index.toIndex()] = .none;
    }

    scope.properties.avatar.equipment_uids[index] = equipment_uids;

    var info: pb.AvatarInfo = try packers.packAvatarInfo(
        scope.sink.allocator,
        &scope.properties.avatar,
        index,
    );

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&info)[0..1]) },
    });

    try scope.sink.respond(pb.EquipmentUnDressScRsp, .init);
}

pub fn AvatarUnlockAwakeCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.AvatarUnlockAwakeCsReq);

    const index = getIndexById(scope, request.avatar_id) orelse
        return try scope.sink.respond(pb.AvatarUnlockAwakeScRsp, .{ .retcode = 1 });

    const avatar_awake_material_count = scope.properties.avatar.awake_material_counts[index];
    if (avatar_awake_material_count == .none or avatar_awake_material_count.toInt() == 0) {
        return try scope.sink.respond(pb.AvatarUnlockAwakeScRsp, .{ .retcode = 1 });
    }

    const meta = &scope.properties.avatar.meta[index];

    // TODO: make it not O(n)
    for (templates.avatar_special_awaken.entries) |template| {
        if (template.avatar_id == request.avatar_id) {
            if (template.id > meta.awakening.toInt()) {
                if (meta.awakening == .none) {
                    meta.flags.awake_available = true;
                    meta.flags.awake_enabled = true;
                }
                meta.awakening = @fromBackingInt(@intCast(template.id));

                scope.properties.avatar.awake_material_counts[index] = @fromBackingInt(
                    avatar_awake_material_count.toInt() - 1,
                );

                break;
            }
        }
    } else return try scope.sink.respond(pb.AvatarUnlockAwakeScRsp, .{ .retcode = 1 });

    var avatar_info: pb.AvatarInfo = try packers.packAvatarInfo(
        scope.sink.allocator,
        &scope.properties.avatar,
        index,
    );

    var material_info: pb.MaterialInfo = .{
        .id = 20_000 + @divFloor(request.avatar_id, 10),
        .count = scope.properties.avatar.awake_material_counts[index].toInt(),
    };

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&avatar_info)[0..1]) },
        .item = .{ .material_list = .fromOwnedSlice((&material_info)[0..1]) },
    });

    try scope.sink.respond(pb.AvatarUnlockAwakeScRsp, .init);
}

pub fn AvatarSetAwakeCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.AvatarSetAwakeCsReq);

    const index = getIndexById(scope, request.avatar_id) orelse
        return try scope.sink.respond(pb.AvatarSetAwakeScRsp, .{ .retcode = 1 });

    var meta = &scope.properties.avatar.meta[index];
    if (meta.awakening == .none) {
        return try scope.sink.respond(pb.AvatarSetAwakeScRsp, .{ .retcode = 1 });
    }

    meta.flags.awake_enabled = request.is_awake_enabled;

    var avatar_info: pb.AvatarInfo = try packers.packAvatarInfo(
        scope.sink.allocator,
        &scope.properties.avatar,
        index,
    );

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&avatar_info)[0..1]) },
    });

    try scope.sink.respond(pb.AvatarSetAwakeScRsp, .init);
}

pub fn MindscapeChangeTabStateCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.MindscapeChangeTabStateCsReq);

    const index = getIndexById(scope, request.avatar_id) orelse
        return try scope.sink.respond(pb.MindscapeChangeTabStateScRsp, .{ .retcode = 1 });

    const tab_state = Properties.Avatar.MindscapeTabState.fromBools(
        request.mindscape_tab_state.items,
    ) orelse
        return try scope.sink.respond(pb.MindscapeChangeTabStateScRsp, .{ .retcode = 1 });

    const meta = &scope.properties.avatar.meta[index];

    if (meta.talents.toInt() < tab_state.requiredTalentNum())
        return try scope.sink.respond(pb.MindscapeChangeTabStateScRsp, .{ .retcode = 1 });

    meta.mindscape_tab_state = tab_state;

    var avatar_info: pb.AvatarInfo = try packers.packAvatarInfo(
        scope.sink.allocator,
        &scope.properties.avatar,
        index,
    );

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&avatar_info)[0..1]) },
    });

    try scope.sink.respond(pb.MindscapeChangeTabStateScRsp, .init);
}

pub fn AvatarShowWeaponToggleCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.AvatarShowWeaponToggleCsReq);

    const index = getIndexById(scope, request.avatar_id) orelse
        return try scope.sink.respond(pb.AvatarShowWeaponToggleScRsp, .{ .retcode = 1 });

    const meta = &scope.properties.avatar.meta[index];

    if (!meta.flags.show_weapon.isUnlocked())
        return try scope.sink.respond(pb.AvatarShowWeaponToggleScRsp, .{ .retcode = 1 });

    const show_weapon: Avatar.Flags.ShowWeapon = switch (request.show_weapon_type orelse .LOCKED) {
        .SHOW => .enabled,
        .HIDE => .disabled,

        // Why would you "lock" this option back?
        .LOCKED => return try scope.sink.respond(pb.AvatarShowWeaponToggleScRsp, .{ .retcode = 1 }),
    };

    meta.flags.show_weapon = show_weapon;

    var avatar_info: pb.AvatarInfo = try packers.packAvatarInfo(
        scope.sink.allocator,
        &scope.properties.avatar,
        index,
    );

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .avatar = .{ .avatar_list = .fromOwnedSlice((&avatar_info)[0..1]) },
    });

    try scope.sink.respond(pb.AvatarShowWeaponToggleScRsp, .init);
}
