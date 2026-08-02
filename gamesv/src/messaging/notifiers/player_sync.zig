pub fn playerSync(
    rtc: logic.RealTimeClock,
    calendar: *const logic.Calendar,
    properties: logic.Properties.Immutable(.{
        logic.Properties.BasicInfo,
        logic.Properties.Avatar,
    }),
    changes: logic.Changes.Subset(.{
        logic.Changes.ControlAvatar,
        logic.Changes.ControlGuiseAvatar,
        logic.Changes.NewAvatar,
        logic.Changes.Avatar,
        logic.Changes.Weapon,
        logic.Changes.Equip,
        logic.Changes.PlayerAccessory,
        logic.Changes.QuickTeam,
        logic.Changes.HadalZoneSchedule,
        logic.Changes.CameraMasterMode,
    }),
    notify: Notify(pb.PlayerSyncScNotify),
) !void {
    var sync: pb.PlayerSyncScNotify = .init;

    sync.self_basic_info = try buildSelfBasicInfo(
        notify.allocator,
        properties.basic_info,
        changes.control_avatar,
        changes.control_guise_avatar,
    );

    sync.avatar = try buildAvatarSync(
        notify.allocator,
        properties.avatar,
        changes.avatars,
        changes.new_avatars,
    );

    sync.misc = .{
        .player_accessory = try buildPlayerAccessory(
            notify.allocator,
            properties.basic_info,
            changes.control_guise_avatar,
            changes.player_accessory,
        ),
        .quick_team = try buildQuickTeamSync(notify.allocator, changes.quick_teams),
        .photo_camera = try buildPhotoCameraSync(notify.allocator, changes.camera_master_mode),
    };

    sync.item = try buildItemSync(
        notify.allocator,
        changes.avatars,
        changes.weapons,
        changes.equipment,
    );

    sync.hadal_zone = try buildHadalZoneSync(
        notify.allocator,
        rtc,
        calendar,
        changes.hadal_zone,
    );

    notify.one(sync);
}

pub fn addAvatar(
    changes: logic.Changes.Subset(.{
        logic.Changes.NewAvatar,
    }),
    notify: Notify(pb.AddAvatarScNotify),
) !void {
    const avatars: []const logic.Changes.NewAvatar = changes.new_avatars;
    var packets: std.ArrayList(pb.AddAvatarScNotify) = .empty;

    for (avatars) |avatar| {
        var add: pb.AddAvatarScNotify = .init;
        add.avatar_id = @intFromEnum(avatar.id);
        add.perform_type = .Gacha;

        packets.append(notify.allocator, add) catch @panic("OOM");
    }

    notify.many(packets.items);
}

fn buildSelfBasicInfo(
    allocator: Allocator,
    info: *const Properties.BasicInfo,
    control_avatar: ?*const logic.Changes.ControlAvatar,
    control_guise_avatar: ?*const logic.Changes.ControlGuiseAvatar,
) !?pb.SelfBasicInfo {
    if (control_avatar == null and control_guise_avatar == null)
        return null;

    return try packers.packSelfBasicInfo(allocator, info);
}

fn buildAvatarSync(
    allocator: Allocator,
    properties: *const logic.Properties.Avatar,
    avatars: []const logic.Changes.Avatar,
    new_avatars: []const logic.Changes.NewAvatar,
) !?pb.AvatarSync {
    if (avatars.len == 0 and new_avatars.len == 0) return null;

    var sync: pb.AvatarSync = .{
        .avatar_list = try .initCapacity(allocator, avatars.len + new_avatars.len),
    };

    for (avatars) |change| sync.avatar_list.appendAssumeCapacity(try packers.packAvatarInfo(
        allocator,
        change.id,
        &change.meta,
        change.weapon_uid,
        change.equipment_uids,
    ));

    for (new_avatars) |new_avatar| {
        const i = properties.indexes.get(new_avatar.id).?;

        sync.avatar_list.appendAssumeCapacity(try packers.packAvatarInfo(
            allocator,
            properties.ids[i],
            &properties.meta[i],
            properties.weapon_uids[i],
            properties.equipment_uids[i],
        ));
    }

    return sync;
}

fn buildPlayerAccessory(
    allocator: Allocator,
    info: *const Properties.BasicInfo,
    maybe_control_guise_avatar: ?*const logic.Changes.ControlGuiseAvatar,
    maybe_player_accessory: ?*const logic.Changes.PlayerAccessory,
) !?pb.PlayerAccessorySync {
    var sync: pb.PlayerAccessorySync = .{};

    if (maybe_control_guise_avatar) |control_guise_avatar| {
        sync.control_guise_avatar_id = control_guise_avatar.guise.toInt();
        sync.control_guise_avatar_skin_id = control_guise_avatar.guise_skin.toInt();
    } else {
        sync.control_guise_avatar_id = info.control_guise_avatar.toInt();
        sync.control_guise_avatar_skin_id = info.control_guise_avatar_skin.toInt();
    }

    if (maybe_player_accessory) |player_accessory|
        try sync.player_accessory_list.append(allocator, .{
            .avatar_id = @intFromEnum(player_accessory.avatar),
            .avatar_skin_id = @intFromEnum(player_accessory.meta.skin),
        });

    return sync;
}

fn buildItemSync(
    allocator: Allocator,
    avatar_changes: []const logic.Changes.Avatar,
    weapon_changes: []const logic.Changes.Weapon,
    equip_changes: []const logic.Changes.Equip,
) !?pb.ItemSync {
    if (avatar_changes.len == 0 and
        weapon_changes.len == 0 and
        equip_changes.len == 0) return null;

    return .{
        .material_list = material_list: {
            var list: ArrayList(pb.MaterialInfo) = try .initCapacity(allocator, avatar_changes.len);

            for (avatar_changes) |avatar_change| {
                list.appendAssumeCapacity(.{
                    .id = 20_000 + @divFloor(@intFromEnum(avatar_change.id), 10),
                    .count = avatar_change.awake_material_count.toInt(),
                });
            }

            break :material_list list;
        },
        .weapon_list = weapon_list: {
            var list: ArrayList(pb.WeaponInfo) = try .initCapacity(allocator, weapon_changes.len);

            for (weapon_changes) |change|
                list.appendAssumeCapacity(.{
                    .uid = change.uid.toInt(),
                    .id = @intFromEnum(change.id),
                    .level = change.level.toInt(),
                    .star = change.star.toInt(),
                    .refine_level = change.refine.toInt(),
                });

            break :weapon_list list;
        },
        .equip_list = equip_list: {
            var list: ArrayList(pb.EquipInfo) = try .initCapacity(allocator, equip_changes.len);

            for (equip_changes) |change|
                list.appendAssumeCapacity(try packers.packEquipmentInfo(
                    allocator,
                    change.uid,
                    change.id,
                    change.level,
                    change.star,
                    &change.properties,
                ));

            break :equip_list list;
        },
    };
}

fn buildQuickTeamSync(allocator: Allocator, quick_teams: []const logic.Changes.QuickTeam) !?pb.QuickTeamSync {
    return if (quick_teams.len == 0) null else try packers.packQuickTeamSync(allocator, quick_teams);
}

fn buildPhotoCameraSync(
    allocator: Allocator,
    maybe_camera_master_mode: ?*const logic.Changes.CameraMasterMode,
) !?pb.PhotoCameraSync {
    var sync: pb.PhotoCameraSync = .{};
    if (maybe_camera_master_mode) |camera_master_mode| {
        var avatar_actions: std.ArrayList(pb.AvatarActionInfo) = try .initCapacity(
            allocator,
            templates.avatar_action_config.entries.len,
        );
        var camera_stickers: std.ArrayList(pb.CameraStickersInfo) = try .initCapacity(
            allocator,
            templates.camera_stickers.entries.len,
        );
        var photo_filters: std.ArrayList(pb.PhotoFilterInfo) = try .initCapacity(
            allocator,
            templates.photo_filters_cfg.entries.len,
        );
        var photo_frames: std.ArrayList(pb.PhotoFrameInfo) = try .initCapacity(
            allocator,
            templates.photo_frame.entries.len,
        );

        for (templates.avatar_action_config.entries) |config|
            avatar_actions.appendAssumeCapacity(.{ .id = @intCast(config.id), .is_unlocked = true });
        for (templates.camera_stickers.entries) |config|
            camera_stickers.appendAssumeCapacity(.{ .id = @intCast(config.id), .is_unlocked = true });
        for (templates.photo_filters_cfg.entries) |config|
            photo_filters.appendAssumeCapacity(.{ .id = @intCast(config.id), .is_unlocked = true });
        for (templates.photo_frame.entries) |config|
            photo_frames.appendAssumeCapacity(.{ .id = @intCast(config.id), .is_unlocked = true });

        sync.photo_filter = photo_filters;
        sync.camera_stickers = camera_stickers;
        sync.photo_frame = photo_frames;
        sync.avatar_action = avatar_actions;
        sync.master_mode = camera_master_mode.master_mode;
    }

    return sync;
}

fn buildHadalZoneSync(
    allocator: Allocator,
    rtc: logic.RealTimeClock,
    calendar: *const logic.Calendar,
    change: ?*const logic.Changes.HadalZoneSchedule,
) !?pb.HadalZoneSync {
    if (change == null) return null;

    var sync: pb.HadalZoneSync = .init;
    try sync.sync_entrance_list.ensureTotalCapacity(
        allocator,
        calendar.hadal_zone.entrance_zones.len,
    );

    for (
        std.enums.values(logic.Calendar.HadalZone.Entrance),
    ) |entrance| if (calendar.hadal_zone.entrance_zones[entrance.toIndex()].unwrap()) |zone_id| {
        const entrance_type: pb.EntranceType = entrance.toEntranceType();

        sync.sync_entrance_list.appendAssumeCapacity(.{
            .entrance_id = entrance.toEntranceId(),
            .state = @enumFromInt(3),
            .cur_zone_record_sync = try packers.packZoneRecord(allocator, rtc.time, entrance_type, zone_id),
        });
    };

    return sync;
}

const Notify = notifiers.Notify;
const ArrayList = std.ArrayList;

const Avatar = Properties.Avatar;
const Allocator = std.mem.Allocator;
const Properties = logic.Properties;

const templates = Assets.templates;

const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const Assets = @import("../../Assets.zig");
const notifiers = @import("../notifiers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
