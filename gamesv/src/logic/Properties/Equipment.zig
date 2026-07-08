pub const capacity = 3_000;

count: u16,
uids: [capacity]Uid,
ids: [capacity]u32,
levels: [capacity]Level,
stars: [capacity]Star,
properties: [capacity]Property.List,

pub const init: Equipment = .{
    .count = 0,
    .uids = undefined,
    .ids = undefined,
    .levels = undefined,
    .stars = undefined,
    .properties = undefined,
};

pub const Uid = enum(u16) {
    _,

    pub const base: u32 = 0x02_00_00;

    /// From the protocol UID representation.
    pub fn fromInt(uid: u32) ?Uid {
        if (uid < base or uid > base + std.math.maxInt(u16))
            return null;

        return @enumFromInt(@as(u16, @intCast(uid - base)));
    }

    /// To the protocol UID representation.
    pub fn toInt(uid: Uid) u32 {
        return @intFromEnum(uid) + base;
    }
};

pub const Level = enum(u8) {
    init = 0,
    max = 15,
    _,

    pub fn toInt(level: Level) u8 {
        return @intFromEnum(level);
    }

    pub fn fromInt(int: u8) ?Level {
        if (int > Level.max.toInt())
            return null;

        return @enumFromInt(int);
    }
};

pub const Star = enum(u8) {
    init = 0,
    max = 5,
    _,

    pub fn toInt(star: Star) u8 {
        return @intFromEnum(star);
    }

    pub fn fromInt(int: u8) ?Star {
        if (int > Star.max.toInt())
            return null;

        return @enumFromInt(int);
    }
};

pub const Slot = enum(u8) {
    _,

    pub fn fromInt(index: u32) ?Slot {
        if (index < 1 or index > 6)
            return null;

        return @enumFromInt(@as(u8, @intCast(index)));
    }

    pub fn toIndex(dress_index: Slot) u8 {
        return @intFromEnum(dress_index) - 1;
    }
};

pub const Property = struct {
    pub const count = 5;

    pub const List = [count]Property;

    key: Key,
    base_value: u16,
    add_value: u16,

    pub const none: Property = .{
        .key = .none,
        .base_value = 0,
        .add_value = 0,
    };

    pub const Key = enum(u16) {
        none = 0,
        _,

        pub inline fn unwrap(key: Key) ?u16 {
            return switch (key) {
                .none => null,
                else => @intFromEnum(key),
            };
        }

        pub inline fn fromInt(int: u16) Key {
            return @enumFromInt(int);
        }
    };
};

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");

const std = @import("std");
const Equipment = @This();
