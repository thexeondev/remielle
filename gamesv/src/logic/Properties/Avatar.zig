const Avatar = @This();
const std = @import("std");

const remielle = @import("remielle");
const templates = remielle.assets.templates;

const Properties = @import("../Properties.zig");

const size = templates.avatar_base.entries.len;

pub const equipment_slots: usize = 6;

pub const Id = templates.avatar_base.Id;
pub const SkinId = templates.avatar_skin_base.Id;

indexes: std.EnumMap(Id, u32),
ids: [size]Id,
meta: [size]Meta,
weapon_uids: [size]OptionalUID,
equipment_uids: [size][equipment_slots]OptionalUID,
awake_material_counts: [size]Awakening.Material,

pub const init: Avatar = .{
    .indexes = .init(.{}),
    .ids = undefined,
    .meta = undefined,
    .weapon_uids = undefined,
    .equipment_uids = undefined,
    .awake_material_counts = undefined,
};

pub const Meta = struct {
    level: Level,
    exp: u32,
    rank: Rank,
    talents: Talents,
    mindscape_tab_state: MindscapeTabState,
    flags: Flags,
    skill_levels: [Skill.count]Skill.Level,
    skin: Skin,
    awakening: Awakening,
};

pub fn count(avatar: *const Avatar) usize {
    return avatar.indexes.count();
}

pub const OptionalUID = enum(u32) {
    none = 0,
    _,

    pub fn unwrap(ou: OptionalUID) ?u32 {
        return switch (ou) {
            .none => null,
            _ => |uid| @intFromEnum(uid),
        };
    }
};

pub const Level = enum(u8) {
    init = 1,
    max = 60,
    _,

    pub fn toInt(level: Level) u8 {
        return @intFromEnum(level);
    }
};

pub const Rank = enum(u8) {
    init = 1,
    max = 6,
    _,

    pub fn toInt(rank: Rank) u8 {
        return @intFromEnum(rank);
    }
};

pub const Talents = enum(u8) {
    init = 0,
    max = 6,
    _,

    pub fn toInt(talents: Talents) u8 {
        return @intFromEnum(talents);
    }
};

pub const Skin = enum(u32) {
    none = 0,
    _,

    pub fn toInt(skin: Skin) u32 {
        return @intFromEnum(skin);
    }
};

pub const Awakening = enum(u32) {
    none = 0,
    _,

    pub fn toInt(awakening: Awakening) u32 {
        return @intFromEnum(awakening);
    }

    pub const Material = enum(u8) {
        none = std.math.maxInt(u8),
        _,

        pub fn toInt(mat: Material) u8 {
            return @intFromEnum(mat);
        }

        pub fn add(mat: Material, num: u8) Material {
            return @enumFromInt(switch (mat) {
                .none => 1,
                else => @intFromEnum(mat) + num,
            });
        }
    };
};

pub const Flags = packed struct {
    favorite: bool,
    awake_available: bool,
    awake_enabled: bool,
    show_weapon: ShowWeapon,

    pub const init: Flags = .{
        .favorite = false,
        .awake_available = false,
        .awake_enabled = false,
        .show_weapon = .locked,
    };

    pub const ShowWeapon = enum(u2) {
        locked = 0b00,
        disabled = 0b01,
        enabled = 0b11,

        pub inline fn isUnlocked(sw: ShowWeapon) bool {
            return (@intFromEnum(sw) & 1) != 0;
        }
    };
};

pub const Skill = enum(u8) {
    pub const count: usize = 7;

    common_attack = 0,
    special_attack = 1,
    evade = 2,
    cooperate_skill = 3,
    unique_skill = 4,
    core_skill = 5,
    assist_skill = 6,

    pub const Level = enum(u8) {
        init = 1,
        _,

        pub fn maxFor(skill: Skill) Skill.Level {
            return @enumFromInt(@as(u8, switch (skill) {
                .core_skill => 7,
                else => 12,
            }));
        }

        pub fn toInt(level: Skill.Level) u8 {
            return @intFromEnum(level);
        }
    };

    pub fn toInt(skill: Skill) u32 {
        return @intFromEnum(skill);
    }
};

pub const MindscapeTabState = enum(u6) {
    pub const tab_count = 6;

    init = 0b000000,
    _,

    pub fn fromBools(bools: []const bool) ?MindscapeTabState {
        if (bools.len != tab_count)
            return null;

        var bits: u6 = 0;
        for (bools, 0..) |bit, index|
            bits |= @as(u6, @intFromBool(bit)) << @intCast(index);

        return .fromBits(bits);
    }

    pub fn toBools(mind: MindscapeTabState) [MindscapeTabState.tab_count]bool {
        const int = @intFromEnum(mind);
        var bools: [MindscapeTabState.tab_count]bool = undefined;

        inline for (&bools, 0..) |*bit, index|
            bit.* = (int >> index) & 1 != 0;

        return bools;
    }

    pub fn fromBits(bits: u6) ?MindscapeTabState {
        if ((bits & 0b111) & ((bits >> 3) & 0b111) != 0)
            return null;

        return @enumFromInt(bits);
    }

    pub fn requiredTalentNum(mind: MindscapeTabState) u3 {
        const int: u6 = @intFromEnum(mind);
        return tab_count - @clz(int);
    }
};
