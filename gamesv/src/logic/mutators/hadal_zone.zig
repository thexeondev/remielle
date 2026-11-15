pub fn mutateHadalZone(
    changes: logic.Changes.Subset(.{
        logic.Changes.HadalZoneRoomFinished,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.HadalZone,
    }),
) !void {
    if (changes.hadal_zone_room_finished) |change| {
        const maybe_layer_id = layer_id: {
            for (Assets.templates.zone_info.entries) |zone_info|
                if (zone_info.zone_id == properties.hadal_zone.zone_id and
                    zone_info.layer_index == properties.hadal_zone.layer_index and
                    zone_info.sub_layer_index == properties.hadal_zone.sub_layer_index)
                {
                    break :layer_id zone_info.layer_id;
                };
            break :layer_id null;
        };
        const maybe_layer_info = if (maybe_layer_id) |layer_id| layer_info: {
            for (Assets.templates.layer_info.entries) |layer_info| if (layer_info.layer_id == layer_id) {
                break :layer_info layer_info;
            };
            break :layer_info null;
        } else null;
        const maybe_room_id = if (maybe_layer_info) |layer_info| room_id: {
            if (properties.hadal_zone.current_room_index < layer_info.layer_room_ids.len) {
                break :room_id layer_info.layer_room_ids[properties.hadal_zone.current_room_index];
            }
            break :room_id null;
        } else null;
        if (maybe_room_id) |room_id| {
            properties.hadal_zone.battle_records[properties.hadal_zone.current_room_index] = .{
                .room_id = room_id,
                .members = change.battle_record_members,
            };
        }
    }

    properties.hadal_zone.current_room_index += 1;
}

const Assets = @import("../../Assets.zig");
const logic = @import("../../logic.zig");
const mutators = @import("../mutators.zig");

const std = @import("std");
