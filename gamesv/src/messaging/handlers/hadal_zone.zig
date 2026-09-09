const std = @import("std");
const ArrayList = std.ArrayList;

const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const templates = remielle.assets.templates;

const logic = @import("../../logic.zig");
const Calendar = logic.Calendar;

const handlers = @import("../handlers.zig");
const Scope = handlers.Scope;

const packers = @import("../packers.zig");

pub fn GetHadalZoneDataCsReq(scope: *Scope) !void {
    var entrance_list_buffer: [scope.calendar.hadal_zone.entrance_zones.len]pb.HadalEntranceInfo = undefined;
    var entrance_list: ArrayList(pb.HadalEntranceInfo) = .initBuffer(&entrance_list_buffer);

    for (std.enums.values(Calendar.HadalZone.Entrance)) |entrance| {
        if (scope.calendar.hadal_zone.entrance_zones[entrance.toIndex()].unwrap()) |zone_id| {
            const entrance_type: pb.EntranceType = entrance.toEntranceType();

            entrance_list.appendAssumeCapacity(.{
                .entrance_type = entrance_type,
                .entrance_id = entrance.toEntranceId(),
                .state = @fromBackingInt(@intCast(3)),
                .cur_zone_record = try packers.packZoneRecord(
                    scope.sink.allocator,
                    scope.clock.time,
                    entrance_type,
                    zone_id,
                ),
            });
        }
    }

    try scope.sink.respond(pb.GetHadalZoneDataScRsp, .{ .hadal_entrance_list = entrance_list });
}
