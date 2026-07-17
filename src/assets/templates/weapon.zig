pub const entries: []const Template = @import("WeaponTemplateTb");

pub const map: std.EnumMap(Id, *const Template) = map: {
    @setEvalBranchQuota(entries.len * entries.len);

    var em: std.EnumMap(Id, *const Template) = .init(.{});
    for (entries) |*entry|
        em.put(entry.getId(), entry);

    break :map em;
};

pub const Id = Id: {
    @setEvalBranchQuota(entries.len * entries.len * entries.len);

    var names: [entries.len][]const u8 = undefined;
    var values: [entries.len]u32 = undefined;

    for (entries, &names, &values) |entry, *name, *value| {
        value.* = entry.item_id;
        name.* = entry.weapon_name;
    }

    break :Id @Enum(u32, .exhaustive, &names, &values);
};

pub const Template = struct {
    item_id: u32,
    weapon_name: []const u8,
    base_property: templates.Property,
    rand_property: templates.Property,
    star_limit: u8,
    exp_recycle: u32,
    refine_initial: u8,
    refine_limit: u8,
    avatar_id: u32,
    refine_costs: []const templates.ItemCount,

    pub inline fn getId(t: *const Template) Id {
        return @enumFromInt(t.item_id);
    }
};

const templates = @import("../templates.zig");
const std = @import("std");
