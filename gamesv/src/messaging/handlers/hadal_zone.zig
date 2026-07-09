pub fn getHadalZoneData(
    rtc: RealTimeClock,
    calendar: *const Calendar,
    message: Message(pb.GetHadalZoneDataCsReq),
    response: Response(pb.GetHadalZoneDataScRsp),
) !void {
    _ = message;

    var entrance_list: ArrayList(pb.HadalEntranceInfo) = try .initCapacity(
        response.allocator,
        calendar.hadal_zone.entrance_zones.len,
    );

    for (
        std.enums.values(Calendar.HadalZone.Entrance),
    ) |entrance| if (calendar.hadal_zone.entrance_zones[entrance.toInt()].unwrap()) |zone_id| {
        const entrance_type: pb.EntranceType = entrance.toEntranceType();

        entrance_list.appendAssumeCapacity(.{
            .entrance_type = entrance_type,
            .entrance_id = entrance.toInt(),
            .state = @enumFromInt(3),
            .cur_zone_record = try packers.packZoneRecord(response.allocator, rtc.time, entrance_type, zone_id),
        });
    };

    response.set(.{ .hadal_entrance_list = entrance_list });
}

const ArrayList = std.ArrayList;
const Message = handlers.Message;
const Response = handlers.Response;
const Calendar = logic.Calendar;
const RealTimeClock = logic.RealTimeClock;

const templates = Assets.templates;

const pb = @import("rmpb").main;
const logic = @import("../../logic.zig");
const packers = @import("../packers.zig");
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");
const std = @import("std");
