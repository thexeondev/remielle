const PlayerAccessory = @This();
const std = @import("std");

const remielle = @import("remielle");
const templates = remielle.assets.templates;

const Properties = @import("../Properties.zig");

pub const slots = 2;

meta: std.EnumArray(Avatar, Meta),

pub const Avatar = enum(u32) {
    wise = @intFromEnum(templates.avatar_base.Id.wise),
    belle = @intFromEnum(templates.avatar_base.Id.belle),

    pub inline fn fromGuise(guise: Properties.HallAvatar.Guise) ?Avatar {
        return std.enums.fromInt(Avatar, @intFromEnum(guise));
    }

    pub inline fn fromGuiseUnchecked(guise: Properties.HallAvatar.Guise) Avatar {
        return @enumFromInt(@intFromEnum(guise));
    }
};

pub const init: PlayerAccessory = .{
    .meta = .initFill(.{
        .skin = .none,
    }),
};

pub const Meta = struct {
    skin: Properties.Avatar.Skin,
};
