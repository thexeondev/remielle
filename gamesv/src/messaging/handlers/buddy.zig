const remielle = @import("remielle");
const pb = remielle.protobuf.main;

pub fn getBuddyData(
    message: Message(pb.GetBuddyDataCsReq),
    properties: Properties.Immutable(.{
        Properties.Buddy,
    }),
    response: Response(pb.GetBuddyDataScRsp),
) !void {
    _ = message;

    const count = properties.buddy.count();
    var infos: ArrayList(pb.BuddyInfo) = try .initCapacity(response.allocator, count);

    for (properties.buddy.ids[0..count], properties.buddy.meta[0..count]) |id, *meta|
        infos.appendAssumeCapacity(try packers.packBuddyInfo(response.allocator, id, meta));

    response.set(.{ .buddy_list = infos });
}

const ArrayList = std.ArrayList;
const Message = handlers.Message;
const Response = handlers.Response;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const handlers = @import("../handlers.zig");

const std = @import("std");
