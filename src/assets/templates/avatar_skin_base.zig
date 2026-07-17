pub const entries: []const Template = @import("AvatarSkinBaseTemplateTb");

pub const map: std.EnumMap(Id, *const Template) = map: {
    @setEvalBranchQuota(entries.len * 1000);

    var em: std.EnumMap(Id, *const Template) = .init(.{});
    for (entries) |*entry|
        em.put(entry.getId(), entry);

    break :map em;
};

pub const Id = Id: {
    @setEvalBranchQuota(entries.len * 1000);
    var names: [entries.len][]const u8 = undefined;
    var values: [entries.len]u32 = undefined;

    for (entries, &names, &values) |entry, *name, *value| {
        value.* = entry.id;
        name.* = std.fmt.comptimePrint("skin_{d}", .{entry.id});
    }

    break :Id @Enum(u32, .exhaustive, &names, &values);
};

pub const Template = struct {
    id: u32,
    avatar_id: u32,

    pub inline fn getId(t: *const Template) Id {
        return @enumFromInt(t.id);
    }
};

const std = @import("std");
