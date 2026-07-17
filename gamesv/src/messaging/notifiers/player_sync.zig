const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

pub fn playerSync(
    rtc: logic.RealTimeClock,
    calendar: *const logic.Calendar,
    properties: logic.Properties.Immutable(.{
        logic.Properties.BasicInfo,
    }),
    changes: logic.Changes.Subset(.{
        logic.Changes.ControlAvatar,
        logic.Changes.ControlGuiseAvatar,
        logic.Changes.Avatar,
        logic.Changes.Weapon,
        logic.Changes.Equip,
        logic.Changes.PlayerAccessory,
        logic.Changes.QuickTeam,
        logic.Changes.HadalZoneSchedule,
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

    sync.avatar = try buildAvatarSync(notify.allocator, changes.avatars);

    sync.misc = .{
        .player_accessory = try buildPlayerAccessory(
            notify.allocator,
            properties.basic_info,
            changes.control_guise_avatar,
            changes.player_accessory,
        ),
        .quick_team = try buildQuickTeamSync(notify.allocator, changes.quick_teams),
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

fn buildAvatarSync(allocator: Allocator, changes: []const logic.Changes.Avatar) !?pb.AvatarSync {
    if (changes.len == 0) return null;

    var sync: pb.AvatarSync = .{
        .avatar_list = try .initCapacity(allocator, changes.len),
    };

    for (changes) |change| sync.avatar_list.appendAssumeCapacity(try packers.packAvatarInfo(
        allocator,
        change.id,
        &change.meta,
        change.weapon_uid,
        change.equipment_uids,
    ));

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
    ) |entrance| if (calendar.hadal_zone.entrance_zones[entrance.toInt()].unwrap()) |zone_id| {
        const entrance_type: pb.EntranceType = entrance.toEntranceType();

        sync.sync_entrance_list.appendAssumeCapacity(.{
            .entrance_id = entrance.toInt(),
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

const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const notifiers = @import("../notifiers.zig");

const std = @import("std");
