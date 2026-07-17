const Buddy = @This();
const std = @import("std");

const remielle = @import("remielle");
const templates = remielle.assets.templates;

const size = templates.buddy_base.entries.len;

pub const Id = templates.buddy_base.Id;

indexes: std.EnumMap(Id, u32),
ids: [size]Id,
meta: [size]Meta,

pub const init: Buddy = .{
    .indexes = .init(.{}),
    .ids = undefined,
    .meta = undefined,
};

pub const Meta = struct {
    level: Level,
    exp: u32,
    rank: Rank,
    star: Star,
    skill_levels: Skill.Levels,
    flags: Flags,
};

pub fn count(buddy: *const Buddy) usize {
    return buddy.indexes.count();
}

pub const Level = enum(u8) {
    init = 1,
    max = 60,
    _,

    pub fn toInt(level: Level) u32 {
        return @intFromEnum(level);
    }
};

pub const Rank = enum(u8) {
    init = 1,
    max = 6,
    _,

    pub fn toInt(rank: Rank) u32 {
        return @intFromEnum(rank);
    }
};

pub const Star = enum(u8) {
    init = 1,
    max = 5,
    _,

    pub fn toInt(star: Star) u32 {
        return @intFromEnum(star);
    }
};

pub const Flags = packed struct {
    favorite: bool,

    pub const init: Flags = .{
        .favorite = false,
    };
};

pub const Skill = enum(u8) {
    manual = 2,
    passive = 3,
    qte = 4,
    aid = 5,

    pub const Levels = std.EnumArray(Skill, Skill.Level);

    pub const Level = enum(u8) {
        init = 1,
        _,

        pub fn maxFor(skill: Skill) Skill.Level {
            return @enumFromInt(@as(u8, switch (skill) {
                .passive => 5,
                else => 8,
            }));
        }

        pub fn toInt(level: Skill.Level) u32 {
            return @intFromEnum(level);
        }
    };

    pub fn toInt(skill: Skill) u32 {
        return @intFromEnum(skill);
    }
};
