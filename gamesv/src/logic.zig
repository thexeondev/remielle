pub const Changes = @import("logic/Changes.zig");
pub const Properties = @import("logic/Properties.zig");

pub const mutators = @import("logic/mutators.zig");

pub const battle = @import("logic/battle.zig");

pub const Calendar = @import("logic/Calendar.zig");

pub const RealTimeClock = struct {
    time: std.Io.Timestamp,
    utc_offset: i32,
};

const std = @import("std");
