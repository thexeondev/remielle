pub fn getServerTimestamp(
    rtc: RealTimeClock,
    message: Message(pb.GetServerTimestampCsReq),
    response: Response(pb.GetServerTimestampScRsp),
) !void {
    _ = message;

    response.set(.{
        .timestamp = @intCast(rtc.time.toMilliseconds()),
        .utc_offset = rtc.utc_offset,
    });
}

pub fn getMiscData(
    message: Message(pb.GetMiscDataCsReq),
    properties: Properties.Immutable(.{
        Properties.BasicInfo,
        Properties.PlayerAccessory,
        Properties.QuickTeam,
    }),
    response: Response(pb.GetMiscDataScRsp),
) !void {
    _ = message;

    var unlocked_list: ArrayList(i32) = try .initCapacity(
        response.allocator,
        templates.unlock_config.entries.len,
    );

    var teleport_list: ArrayList(i32) = try .initCapacity(
        response.allocator,
        templates.teleport_config.entries.len,
    );

    var post_girls: ArrayList(pb.PostGirlItem) = try .initCapacity(
        response.allocator,
        templates.post_girl_config.entries.len,
    );

    for (templates.unlock_config.entries) |config|
        unlocked_list.appendAssumeCapacity(@intCast(config.id));

    for (templates.teleport_config.entries) |config|
        teleport_list.appendAssumeCapacity(@intCast(config.teleport_id));

    for (templates.post_girl_config.entries) |config|
        post_girls.appendAssumeCapacity(.{ .id = config.id });

    var show_post_girls: std.ArrayList(u32) = try .initCapacity(response.allocator, 1);
    show_post_girls.appendAssumeCapacity(
        3510056,
    );

    var player_accessory_list: std.ArrayList(pb.PlayerAccessoryInfo) = try .initCapacity(response.allocator, Properties.PlayerAccessory.slots);
    inline for (std.enums.values(Properties.PlayerAccessory.Avatar)) |avatar| player_accessory_list.appendAssumeCapacity(.{
        .avatar_id = @intFromEnum(avatar),
        .avatar_skin_id = @intFromEnum(properties.player_accessory.meta.get(avatar).skin),
    });

    var avatar_actions: std.ArrayList(pb.AvatarActionInfo) = try .initCapacity(
        response.allocator,
        templates.avatar_action_config.entries.len,
    );
    var camera_stickers: std.ArrayList(pb.CameraStickersInfo) = try .initCapacity(
        response.allocator,
        templates.camera_stickers.entries.len,
    );
    var photo_filters: std.ArrayList(pb.PhotoFilterInfo) = try .initCapacity(
        response.allocator,
        templates.photo_filters_cfg.entries.len,
    );
    var photo_frames: std.ArrayList(pb.PhotoFrameInfo) = try .initCapacity(
        response.allocator,
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

    response.set(.{ .data = .{
        .unlock = .{ .unlocked_list = unlocked_list },
        .teleport = .{ .unlocked_list = teleport_list },
        .post_girl = .{
            .post_girl_item_list = post_girls,
            .show_post_girl_id_list = show_post_girls,
        },
        .business_card = .init,
        .player_accessory = .{
            .control_guise_avatar_id = properties.basic_info.control_guise_avatar.toInt(),
            .control_guise_avatar_skin_id = properties.basic_info.control_guise_avatar_skin.toInt(),
            .player_accessory_list = player_accessory_list,
        },
        .quick_team = try packers.packQuickTeamData(response.allocator, &properties.quick_team.meta),
        .photo_camera = .{
            .photo_filter = photo_filters,
            .camera_stickers = camera_stickers,
            .photo_frame = photo_frames,
            .avatar_action = avatar_actions,
            .master_mode = false,
        },
    } });
}

pub fn cameraMasterModeToggle(
    message: Message(pb.CameraMasterModeToggleCsReq),
    changes: Changes.Builder(.{
        Changes.CameraMasterMode,
    }),
    response: Response(pb.CameraMasterModeToggleScRsp),
) !void {
    const camera_master_mode: Changes.CameraMasterMode = .{
        .master_mode = message.data.master_mode,
    };

    changes.insert(camera_master_mode);

    response.set(.init);
}

const templates = Assets.templates;

const ArrayList = std.ArrayList;

const Message = handlers.Message;
const Response = handlers.Response;

const Changes = logic.Changes;
const Properties = logic.Properties;
const RealTimeClock = logic.RealTimeClock;

const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");
const packers = @import("../packers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
