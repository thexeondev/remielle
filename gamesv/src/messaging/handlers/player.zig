const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

pub fn playerLogin(
    message: Message(pb.PlayerLoginCsReq),
    response: Response(pb.PlayerLoginScRsp),
) !void {
    _ = message;
    response.set(.init);
}

pub fn keepAlive(message: Message(pb.KeepAliveNotify)) !void {
    _ = message;
}

pub fn getSelfBasicInfo(
    message: Message(pb.GetSelfBasicInfoCsReq),
    properties: Properties.Immutable(.{
        Properties.BasicInfo,
    }),
    response: Response(pb.GetSelfBasicInfoScRsp),
) !void {
    _ = message;

    response.set(.{ .self_basic_info = try packers.packSelfBasicInfo(
        response.allocator,
        properties.basic_info,
    ) });
}

pub fn modPlayerAccessory(
    message: Message(pb.SavePlayerAccessoryCsReq),
    changes: Changes.Builder(.{
        Changes.PlayerAccessory,
    }),
    response: Response(pb.SavePlayerAccessoryScRsp),
) !void {
    const player_accessory = message.data.player_accessory orelse
        return response.fail(1);

    const new_skin = templates.avatar_skin_base.map.get(@enumFromInt(player_accessory.avatar_skin_id)) orelse
        return response.fail(1);

    if (new_skin.avatar_id != player_accessory.avatar_id)
        return response.fail(1);

    changes.insert(Changes.PlayerAccessory{
        .avatar = std.enums.fromInt(Properties.PlayerAccessory.Avatar, new_skin.avatar_id) orelse return response.fail(1),
        .meta = .{ .skin = @enumFromInt(new_skin.id) },
    });

    response.set(.init);
}

pub fn modAvatar(
    message: Message(pb.ModAvatarCsReq),
    properties: Properties.Immutable(.{
        Properties.BasicInfo,
        Properties.Avatar,
        Properties.PlayerAccessory,
    }),
    changes: Changes.Builder(.{
        Changes.ControlAvatar,
        Changes.ControlGuiseAvatar,
    }),
    response: Response(pb.ModAvatarScRsp),
) !void {
    const new_control_avatar = Properties.HallAvatar.fromInt(message.data.control_avatar_id) orelse
        return response.fail(1);

    const new_guise = Properties.HallAvatar.Guise.fromRawId(
        properties.avatar,
        message.data.control_guise_avatar_id,
    ) catch |err| return switch (err) {
        error.InvalidAvatarId,
        error.AvatarNotUnlocked,
        => response.fail(1),
    };

    if (properties.basic_info.control_avatar != new_control_avatar)
        changes.insert(new_control_avatar);

    if (properties.basic_info.control_guise_avatar != new_guise)
        changes.insert(Changes.ControlGuiseAvatar{
            .guise = new_guise,
            .guise_skin = new_guise.getSkin(
                properties.avatar,
                properties.player_accessory,
            ),
        });

    response.set(.init);
}

const Message = handlers.Message;
const Response = handlers.Response;

const Changes = logic.Changes;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const handlers = @import("../handlers.zig");

const std = @import("std");
