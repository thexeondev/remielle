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
    ) |entrance| if (calendar.hadal_zone.entrance_zones[entrance.toIndex()].unwrap()) |zone_id| {
        const entrance_type: pb.EntranceType = entrance.toEntranceType();

        entrance_list.appendAssumeCapacity(.{
            .entrance_type = entrance_type,
            .entrance_id = entrance.toEntranceId(),
            .state = @enumFromInt(3),
            .cur_zone_record = try packers.packZoneRecord(response.allocator, rtc.time, entrance_type, zone_id),
        });
    };

    response.set(.{ .hadal_entrance_list = entrance_list });
}

pub fn endHadalZoneRoom(
    message: Message(pb.EndHadalZoneRoomCsReq),
    changes: logic.Changes.Builder(.{
        logic.Changes.HadalZoneRoomFinished,
    }),
    response: Response(pb.EndHadalZoneRoomScRsp),
) !void {
    if (message.data.result.?.battle_data_record) |battle_data_record| {
        changes.insert(logic.Changes.HadalZoneRoomFinished{
            .battle_record_members = battle_records: {
                var battle_records: [logic.Properties.HadalZone.max_battle_record_members_count]logic.Properties.HadalZone.BattleRecordMember = undefined;

                for (&battle_records, 0..) |*battle_record, i| {
                    if (i == logic.Properties.HadalZone.max_avatar_per_room_count) {
                        battle_record.* = .fromBattleRecordMemberData(battle_data_record.buddy_member_data);
                        break;
                    }
                    const maybe_battle_record_member_data = if (i < battle_data_record.avatar_member_list.items.len) battle_data_record.avatar_member_list.items[i] else null;
                    battle_record.* = .fromBattleRecordMemberData(maybe_battle_record_member_data);
                }

                break :battle_records battle_records;
            },
        });
    }

    response.set(.init);
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
