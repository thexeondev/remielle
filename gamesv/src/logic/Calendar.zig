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
            ez[Entrance.free_training.toIndex()] = @enumFromInt(890011);
            ez[Entrance.hadal_zone_scheduled_1.toIndex()] = @enumFromInt(620571);
            ez[Entrance.hadal_zone_stable.toIndex()] = @enumFromInt(61001);
            ez[Entrance.hadal_zone_defensive.toIndex()] = @enumFromInt(61002);
            ez[Entrance.hadal_zone_ambush.toIndex()] = @enumFromInt(61003);
            ez[Entrance.boss_challenge_trial_1.toIndex()] = @enumFromInt(6904511);
            ez[Entrance.boss_challenge_trial_2.toIndex()] = @enumFromInt(6904611);
            ez[Entrance.boss_challenge_trial_3.toIndex()] = @enumFromInt(6904711);
            ez[Entrance.hadal_zone_scheduled_2.toIndex()] = @enumFromInt(620581);
            ez[Entrance.hadal_zone_scheduled_3.toIndex()] = @enumFromInt(620591);
            ez[Entrance.boss_challenge_adversity_1.toIndex()] = @enumFromInt(690422);
            ez[Entrance.boss_challenge_adversity_2.toIndex()] = @enumFromInt(6904521);
            ez[Entrance.boss_challenge_adversity_3.toIndex()] = @enumFromInt(6904621);
            ez[Entrance.boss_challenge_adversity_4.toIndex()] = @enumFromInt(6904721);

            break :entrance_zones ez;
        },
    };

    pub const Entrance = enum(u32) {
        free_training = 0,
        hadal_zone_scheduled_1 = 1,
        hadal_zone_stable = 2,
        hadal_zone_defensive = 3,
        hadal_zone_ambush = 4,
        boss_challenge_trial_1 = 9,
        boss_challenge_trial_2 = 10,
        boss_challenge_trial_3 = 11,
        // 12 is an empty spacer
        hadal_zone_scheduled_2 = 13,
        hadal_zone_scheduled_3 = 14,
        // 15 is an empty spacer
        boss_challenge_adversity_1 = 16,
        boss_challenge_adversity_2 = 17,
        boss_challenge_adversity_3 = 18,
        boss_challenge_adversity_4 = 19,

        const count: u32 = count: {
            var highest: u32 = 0;
            for (@typeInfo(Entrance).@"enum".fields) |enum_field| {
                highest = @max(highest, enum_field.value);
            }

            break :count highest + 1;
        };

        pub fn toIndex(e: Entrance) u32 {
            return @intFromEnum(e);
        }

        pub fn toEntranceId(e: Entrance) u32 {
            return switch (e) {
                .free_training => 901, // hard-coded to reduce array size
                else => @intFromEnum(e),
            };
        }

        pub fn toEntranceType(e: Entrance) pb.EntranceType {
            return switch (e) {
                .hadal_zone_stable,
                .hadal_zone_defensive,
                => .CONSTANT,

                else => .SCHEDULED,
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
