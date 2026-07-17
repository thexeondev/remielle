pub const entries: []const Template = @import("UrbanAreaMapGroupTemplateTb");

pub const Id = Id: {
    @setEvalBranchQuota(entries.len * entries.len * entries.len);

    var names: [entries.len][]const u8 = undefined;
    var values: [entries.len]u32 = undefined;

    for (entries, &names, &values) |entry, *name, *value| {
        value.* = entry.area_group_id;
        name.* = entry.group_name;
    }

    break :Id @Enum(u32, .exhaustive, &names, &values);
};

pub const Template = struct {
    area_group_id: u32,
    group_name: []const u8,
    is_map_visible: bool,

    pub inline fn getId(t: *const Template) Id {
        return @enumFromInt(t.area_group_id);
    }
};

const templates = @import("../templates.zig");
