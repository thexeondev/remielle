hadal_zone: HadalZone,

pub const init: Calendar = .{
    .hadal_zone = .init,
};

const save_version: u32 = 0;

pub const HadalZone = extern struct {
    entrance_zones: [Entrance.count]OptionalZone,

    pub const init: HadalZone = .{
        .entrance_zones = entrance_zones: {
            var ez: [Entrance.count]OptionalZone = @splat(.none);
            ez[Entrance.hadal_zone_scheduled.toInt()] = @enumFromInt(620561);
            ez[Entrance.hadal_zone_stable.toInt()] = @enumFromInt(61001);
            ez[Entrance.hadal_zone_defensive.toInt()] = @enumFromInt(61002);
            ez[Entrance.boss_challenge_normal.toInt()] = @enumFromInt(6904211);
            ez[Entrance.boss_challenge_hard.toInt()] = @enumFromInt(690422);

            break :entrance_zones ez;
        },
    };

    pub const Entrance = enum(u32) {
        hadal_zone_scheduled = 1,
        hadal_zone_stable = 2,
        hadal_zone_defensive = 3,
        boss_challenge_normal = 9,
        boss_challenge_hard = 16,

        const count: u32 = count: {
            var highest: u32 = 0;
            for (@typeInfo(Entrance).@"enum".fields) |enum_field| {
                highest = @max(highest, enum_field.value);
            }

            break :count highest + 1;
        };

        pub fn toInt(e: Entrance) u32 {
            return @intFromEnum(e);
        }

        pub fn toEntranceType(e: Entrance) pb.EntranceType {
            return switch (e) {
                .hadal_zone_stable,
                .hadal_zone_defensive,
                => .CONSTANT,

                .hadal_zone_scheduled,
                .boss_challenge_normal,
                .boss_challenge_hard,
                => .SCHEDULED,
            };
        }
    };

    pub const OptionalZone = enum(u32) {
        none = 0,
        _,

        pub fn unwrap(oz: OptionalZone) ?u32 {
            return switch (oz) {
                .none => null,
                _ => |zone| @intFromEnum(zone),
            };
        }
    };
};

pub fn load(calendar: *Calendar, reader: *Io.Reader) !void {
    if (try reader.takeInt(u32, .little) != save_version)
        return error.VersionMismatch;

    try reader.readSliceAll(@ptrCast(&calendar.hadal_zone));
}

pub fn save(calendar: *const Calendar, writer: *Io.Writer) !void {
    try writer.writeInt(u32, save_version, .little);
    try writer.writeAll(@ptrCast(&calendar.hadal_zone));
}

const Io = std.Io;

const pb = @import("rmpb").main;

const std = @import("std");
const Calendar = @This();
