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
        const entrance_type: pb.EntranceType = switch (entrance) {
            .hadal_zone_stable,
            .hadal_zone_defensive,
            => .CONSTANT,

            .hadal_zone_scheduled,
            .boss_challenge_normal,
            .boss_challenge_hard,
            => .SCHEDULED,
        };

        entrance_list.appendAssumeCapacity(.{
            .entrance_type = entrance_type,
            .entrance_id = entrance.toInt(),
            .state = @enumFromInt(3),
            .cur_zone_record = .{
                .zone_id = zone_id,
                .begin_timestamp = switch (entrance_type) {
                    .NONE, .CONSTANT => 0,
                    .SCHEDULED => @intCast(rtc.time.toSeconds() - 3600 * 24),
                },
                .end_timestamp = switch (entrance_type) {
                    .NONE, .CONSTANT => 0,
                    .SCHEDULED => @intCast(rtc.time.toSeconds() + 3600 * 24 * 14),
                },
                .layer_record_list = layer_record_list: {
                    var list: ArrayList(pb.LayerRecord) = .empty;

                    for (templates.zone_info.entries) |zone_info| if (zone_info.zone_id == zone_id) {
                        try list.append(response.allocator, .{
                            .layer_index = zone_info.layer_index,
                            .status = @enumFromInt(4),
                        });
                    };

                    break :layer_record_list list;
                },
            },
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
const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");
const std = @import("std");
