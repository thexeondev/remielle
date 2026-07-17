const remielle = @import("remielle");
const templates = remielle.assets.templates;

pub fn modHadalZoneSchedule(
    extended: control.ExtendedOperation(remielle.control.Operation.ModHadalZoneSchedule),
    context: *const control.Context,
) !void {
    const server = context.server;
    var hadal_zone = server.persistent.calendar.hadal_zone;

    for (extended.entries) |*entry| {
        const entrance = std.enums.fromInt(Calendar.HadalZone.Entrance, entry.entrance_id) orelse
            return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

        for (templates.zone_info.entries) |zone_info| {
            if (zone_info.zone_id == entry.zone_id)
                break;
        } else return context.sendEvent(remielle.control.Event.Nak, .{ .reason = .invalid_parameter, .extra = 0 });

        hadal_zone.entrance_zones[entrance.toInt()] = @enumFromInt(entry.zone_id);
    }

    server.persistent.calendar.hadal_zone = hadal_zone;
    try context.sendEvent(remielle.control.Event.Ack, .{});

    var session_index: u32 = 0;
    while (session_index < server.conv_map.count()) : (session_index += 1) {
        const arena = server.resettable_arena.allocator();
        defer _ = server.resettable_arena.reset(.retain_capacity);

        var changes: logic.Changes = .init;
        changes.hadal_zone = .{};

        const frame: Server.Frame = .{
            .target_index = session_index,
            .time = context.time,
            .clients = &server.clients,
            .asset_lookup = server.asset_lookup,
            .properties = &server.properties,
            .calendar = &server.persistent.calendar,
            .multi_conversation = &server.multi_conversation,
        };

        try logic.mutators.dispatchLogicChanges(&frame, &changes);
        try messaging.notifiers.notifyLogicChanges(arena, &frame, &changes);
    }
}

const Calendar = logic.Calendar;

const app = @import("../app.zig");
const logic = @import("../logic.zig");
const Server = @import("../Server.zig");
const control = @import("../control.zig");
const messaging = @import("../messaging.zig");

const std = @import("std");
