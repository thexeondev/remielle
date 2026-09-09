const std = @import("std");
const ArrayList = std.ArrayList;

const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const handlers = @import("../handlers.zig");

const Scope = handlers.Scope;

const remielle = @import("remielle");
const pb = remielle.protobuf.main;

pub fn GetBuddyDataCsReq(scope: *Scope) !void {
    const count = scope.properties.buddy.count();
    var infos: ArrayList(pb.BuddyInfo) = try .initCapacity(scope.sink.allocator, count);

    for (
        scope.properties.buddy.ids[0..count],
        scope.properties.buddy.meta[0..count],
    ) |id, *meta|
        infos.appendAssumeCapacity(try packers.packBuddyInfo(scope.sink.allocator, id, meta));

    try scope.sink.respond(pb.GetBuddyDataScRsp, .{ .buddy_list = infos });
}
