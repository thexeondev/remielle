const QuickTeam = @This();
const std = @import("std");

const remielle = @import("remielle");
const LimitedString = remielle.mem.LimitedString;

pub const slots = 20;
pub const avatar_slots = 3;
pub const Name = LimitedString(14);

meta: [slots]Meta,

pub const init: QuickTeam = std.mem.zeroes(QuickTeam);

pub const Meta = struct {
    name: Name,
    avatar_ids: [avatar_slots]OptionalID,
    buddy_id: OptionalID,
};

pub const Slot = enum(u8) {
    _,

    pub fn fromInt(slot: u32) ?Slot {
        if (slot < 1 or slot > slots)
            return null;

        return @enumFromInt(@as(u8, @intCast(slot)));
    }

    pub fn toIndex(slot: Slot) u8 {
        return @intFromEnum(slot) - 1;
    }
};

pub const OptionalID = enum(u32) {
    none = 0,
    _,

    pub fn unwrap(o: OptionalID) ?u32 {
        return switch (o) {
            .none => null,
            _ => |id| @intFromEnum(id),
        };
    }
};
