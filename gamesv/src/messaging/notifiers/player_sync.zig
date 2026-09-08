const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

pub fn playerSync(
    changes: logic.Changes.Subset(.{
        logic.Changes.Avatar,
        logic.Changes.PlayerAccessory,
    }),
    notify: Notify(pb.PlayerSyncScNotify),
) !void {
    var sync: pb.PlayerSyncScNotify = .init;

    sync.avatar = try buildAvatarSync(notify.allocator, changes.avatars);

    sync.misc = .{
        .player_accessory = try buildPlayerAccessory(
            notify.allocator,
            changes.player_accessory,
        ),
    };

    sync.item = try buildItemSync(
        notify.allocator,
        changes.avatars,
    );

    notify.one(sync);
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
    maybe_player_accessory: ?*const logic.Changes.PlayerAccessory,
) !?pb.PlayerAccessorySync {
    var sync: pb.PlayerAccessorySync = .{};

    if (maybe_player_accessory) |player_accessory|
        try sync.player_accessory_list.append(allocator, .{
            .avatar_id = @backingInt(player_accessory.avatar),
            .avatar_skin_id = @backingInt(player_accessory.meta.skin),
        });

    return sync;
}

fn buildItemSync(
    allocator: Allocator,
    avatar_changes: []const logic.Changes.Avatar,
) !?pb.ItemSync {
    if (avatar_changes.len == 0) return null;

    return .{
        .material_list = material_list: {
            var list: ArrayList(pb.MaterialInfo) = try .initCapacity(allocator, avatar_changes.len);

            for (avatar_changes) |avatar_change| {
                list.appendAssumeCapacity(.{
                    .id = 20_000 + @divFloor(@backingInt(avatar_change.id), 10),
                    .count = avatar_change.awake_material_count.toInt(),
                });
            }

            break :material_list list;
        },
    };
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
