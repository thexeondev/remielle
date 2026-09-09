const std = @import("std");
const ArrayList = std.ArrayList;

const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

const handlers = @import("../handlers.zig");
const Scope = handlers.Scope;

pub fn GetAreaMapDataCsReq(scope: *Scope) !void {
    var groups_buffer: [templates.urban_area_map_group.entries.len]pb.AreaGroupInfo = undefined;
    var groups: ArrayList(pb.AreaGroupInfo) = .initBuffer(&groups_buffer);

    for (templates.urban_area_map_group.entries) |entry| if (entry.is_map_visible)
        groups.appendAssumeCapacity(.{
            .group_id = entry.area_group_id,
            .area_progress = 99,
            .is_unlocked = true,
        });

    var streets_buffer: [templates.urban_area_map.entries.len]pb.AreaStreetInfo = undefined;
    var streets: ArrayList(pb.AreaStreetInfo) = .initBuffer(&streets_buffer);

    for (templates.urban_area_map.entries) |entry|
        streets.appendAssumeCapacity(.{
            .area_id = entry.area_id,
            .area_progress = 99,
            .is_unlocked = true,
            .is_area_pop_show = true,
            .is_urban_area_show = true,
            .is_3d_area_show = true,
        });

    try scope.sink.respond(pb.GetAreaMapDataScRsp, .{ .data = .{
        .group = groups,
        .street = streets,
    } });
}

pub fn GetNewAreaPortalListCsReq(scope: *Scope) !void {
    try scope.sink.respond(pb.GetNewAreaPortalListScRsp, .init);
}
