const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

pub fn getAreaMapData(
    message: Message(pb.GetAreaMapDataCsReq),
    response: Response(pb.GetAreaMapDataScRsp),
) !void {
    _ = message;

    var groups: ArrayList(pb.AreaGroupInfo) = try .initCapacity(
        response.allocator,
        templates.urban_area_map_group.entries.len,
    );

    for (templates.urban_area_map_group.entries) |entry| if (entry.is_map_visible)
        groups.appendAssumeCapacity(.{
            .group_id = entry.area_group_id,
            .area_progress = 99,
            .is_unlocked = true,
        });

    var streets: ArrayList(pb.AreaStreetInfo) = try .initCapacity(
        response.allocator,
        templates.urban_area_map.entries.len,
    );

    for (templates.urban_area_map.entries) |entry|
        streets.appendAssumeCapacity(.{
            .area_id = entry.area_id,
            .area_progress = 99,
            .is_unlocked = true,
            .is_area_pop_show = true,
            .is_urban_area_show = true,
            .is_3d_area_show = true,
        });

    response.set(.{ .data = .{
        .group = groups,
        .street = streets,
    } });
}

const ArrayList = std.ArrayList;
const Message = handlers.Message;
const Response = handlers.Response;

const handlers = @import("../handlers.zig");
const std = @import("std");
