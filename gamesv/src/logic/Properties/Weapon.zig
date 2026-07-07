pub const capacity = 2_000;

pub const Id = templates.weapon.Id;

count: u16,
uids: [capacity]Uid,
ids: [capacity]Id,
levels: [capacity]Level,
stars: [capacity]Star,
refines: [capacity]Refine,

pub const init: Weapon = .{
    .count = 0,
    .uids = undefined,
    .ids = undefined,
    .levels = undefined,
    .stars = undefined,
    .refines = undefined,
};

pub const Uid = enum(u16) {
    _,

    pub const base: u32 = 0x01_00_00;

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
    init = 1,
    max = 60,
    _,

    pub fn toInt(level: Level) u8 {
        return @intFromEnum(level);
    }

    pub fn fromInt(int: u8) ?Level {
        if (int < Level.init.toInt() or int > Level.max.toInt())
            return null;

        return @enumFromInt(int);
    }
};

pub const Star = enum(u8) {
    init = 1,
    max = 5,
    _,

    pub fn toInt(star: Star) u8 {
        return @intFromEnum(star);
    }

    pub fn fromInt(int: u8) ?Star {
        if (int < Star.init.toInt() or int > Star.max.toInt())
            return null;

        return @enumFromInt(int);
    }
};

pub const Refine = enum(u8) {
    init = 1,
    max = 5,
    _,

    pub fn toInt(refine: Refine) u8 {
        return @intFromEnum(refine);
    }

    pub fn fromInt(int: u8) ?Refine {
        if (int < Refine.init.toInt() or int > Refine.max.toInt())
            return null;

        return @enumFromInt(int);
    }
};

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");

const std = @import("std");
const Weapon = @This();
