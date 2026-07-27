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
    } });
}

const templates = Assets.templates;

const ArrayList = std.ArrayList;

const Message = handlers.Message;
const Response = handlers.Response;

const Properties = logic.Properties;
const RealTimeClock = logic.RealTimeClock;

const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");
const packers = @import("../packers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
