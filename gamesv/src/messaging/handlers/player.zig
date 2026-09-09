const std = @import("std");

const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const handlers = @import("../handlers.zig");

const Scope = handlers.Scope;
const Properties = logic.Properties;

pub fn PlayerLoginCsReq(
    scope: *Scope,
) !void {
    try scope.sink.respond(pb.PlayerLoginScRsp, .init);
}

pub fn KeepAliveNotify(scope: *Scope) !void {
    _ = scope;
}

pub fn GetSelfBasicInfoCsReq(scope: *Scope) !void {
    try scope.sink.respond(pb.GetSelfBasicInfoScRsp, .{
        .self_basic_info = try packers.packSelfBasicInfo(
            scope.sink.allocator,
            &scope.properties.basic_info,
        ),
    });
}

pub fn SavePlayerAccessoryCsReq(
    scope: *Scope,
) !void {
    const request = try scope.source.take(pb.SavePlayerAccessoryCsReq);

    const player_accessory = request.player_accessory orelse
        return try scope.sink.respond(pb.SavePlayerAccessoryScRsp, .{ .retcode = 1 });

    const new_skin = templates.avatar_skin_base.map.get(
        @fromBackingInt(@intCast(player_accessory.avatar_skin_id)),
    ) orelse
        return try scope.sink.respond(pb.SavePlayerAccessoryScRsp, .{ .retcode = 1 });

    if (new_skin.avatar_id != player_accessory.avatar_id)
        return try scope.sink.respond(pb.SavePlayerAccessoryScRsp, .{ .retcode = 1 });

    const new_avatar = std.enums.fromInt(Properties.PlayerAccessory.Avatar, new_skin.avatar_id) orelse
        return try scope.sink.respond(pb.SavePlayerAccessoryScRsp, .{ .retcode = 1 });

    const new_meta: Properties.PlayerAccessory.Meta = .{
        .skin = @fromBackingInt(@intCast(new_skin.id)),
    };

    scope.properties.player_accessory.meta.set(new_avatar, new_meta);

    var sync_info: pb.PlayerAccessoryInfo = .{
        .avatar_id = @backingInt(new_avatar),
        .avatar_skin_id = @backingInt(new_meta.skin),
    };

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .misc = .{
            .player_accessory = .{
                .player_accessory_list = .fromOwnedSlice((&sync_info)[0..1]),
            },
        },
    });

    try scope.sink.respond(pb.SavePlayerAccessoryScRsp, .init);
}

pub fn ModAvatarCsReq(
    scope: *Scope,
) !void {
    const request = try scope.source.take(pb.ModAvatarCsReq);

    const new_control_avatar = Properties.HallAvatar.fromInt(request.control_avatar_id) orelse
        return try scope.sink.respond(pb.ModAvatarScRsp, .{ .retcode = 1 });

    const new_guise = Properties.HallAvatar.Guise.fromRawId(
        &scope.properties.avatar,
        request.control_guise_avatar_id,
    ) catch |err| return switch (err) {
        error.InvalidAvatarId,
        error.AvatarNotUnlocked,
        => try scope.sink.respond(pb.ModAvatarScRsp, .{ .retcode = 1 }),
    };

    scope.properties.basic_info.control_avatar = new_control_avatar;
    scope.properties.basic_info.control_guise_avatar = new_guise;
    scope.properties.basic_info.control_guise_avatar_skin = new_guise.getSkin(
        &scope.properties.avatar,
        &scope.properties.player_accessory,
    );

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .self_basic_info = try packers.packSelfBasicInfo(
            scope.sink.allocator,
            &scope.properties.basic_info,
        ),
        .misc = .{
            .player_accessory = .{
                .control_guise_avatar_id = scope.properties.basic_info.control_guise_avatar.toInt(),
                .control_guise_avatar_skin_id = scope.properties.basic_info.control_guise_avatar_skin.toInt(),
            },
        },
    });

    try scope.sink.respond(pb.ModAvatarScRsp, .init);
}
