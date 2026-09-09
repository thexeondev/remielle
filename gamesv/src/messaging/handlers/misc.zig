const std = @import("std");
const ArrayList = std.ArrayList;

const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

const handlers = @import("../handlers.zig");
const Scope = handlers.Scope;

const packers = @import("../packers.zig");

const logic = @import("../../logic.zig");
const Properties = logic.Properties;

pub fn GetServerTimestampCsReq(scope: *Scope) !void {
    try scope.sink.respond(pb.GetServerTimestampScRsp, .{
        .timestamp = @intCast(scope.clock.time.toMilliseconds()),
        .utc_offset = scope.clock.utc_offset,
    });
}

pub fn GetMiscDataCsReq(scope: *Scope) !void {
    var unlocked_list_buffer: [templates.unlock_config.entries.len]i32 = undefined;
    var unlocked_list: ArrayList(i32) = .initBuffer(&unlocked_list_buffer);

    var teleport_list_buffer: [templates.teleport_config.entries.len]i32 = undefined;
    var teleport_list: ArrayList(i32) = .initBuffer(&teleport_list_buffer);

    var post_girls_buffer: [templates.post_girl_config.entries.len]pb.PostGirlItem = undefined;
    var post_girls: ArrayList(pb.PostGirlItem) = .initBuffer(&post_girls_buffer);

    for (templates.unlock_config.entries) |config|
        unlocked_list.appendAssumeCapacity(@intCast(config.id));

    for (templates.teleport_config.entries) |config|
        teleport_list.appendAssumeCapacity(@intCast(config.teleport_id));

    for (templates.post_girl_config.entries) |config|
        post_girls.appendAssumeCapacity(.{ .id = config.id });

    var show_post_girl: u32 = 3510055;

    var player_accessory_buffer: [Properties.PlayerAccessory.slots]pb.PlayerAccessoryInfo = undefined;
    var player_accessory_list: ArrayList(pb.PlayerAccessoryInfo) = .initBuffer(&player_accessory_buffer);

    inline for (std.enums.values(Properties.PlayerAccessory.Avatar)) |avatar|
        player_accessory_list.appendAssumeCapacity(.{
            .avatar_id = @backingInt(avatar),
            .avatar_skin_id = @backingInt(scope.properties.player_accessory.meta.get(avatar).skin),
        });

    try scope.sink.respond(pb.GetMiscDataScRsp, .{ .data = .{
        .unlock = .{ .unlocked_list = unlocked_list },
        .teleport = .{ .unlocked_list = teleport_list },
        .post_girl = .{
            .post_girl_item_list = post_girls,
            .show_post_girl_id_list = .fromOwnedSlice((&show_post_girl)[0..1]),
        },
        .business_card = .init,
        .player_accessory = .{
            .control_guise_avatar_id = scope.properties.basic_info.control_guise_avatar.toInt(),
            .control_guise_avatar_skin_id = scope.properties.basic_info.control_guise_avatar_skin.toInt(),
            .player_accessory_list = player_accessory_list,
        },
        .quick_team = .{
            .quick_team_list = try packers.packQuickTeamList(
                scope.sink.allocator,
                &scope.properties.quick_team.meta,
            ),
        },
    } });
}
