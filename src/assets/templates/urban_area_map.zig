pub const entries: []const Template = @import("UrbanAreaMapTemplateTb");

pub const Id = Id: {
    @setEvalBranchQuota(entries.len * entries.len * entries.len);

    var names: [entries.len][]const u8 = undefined;
    var values: [entries.len]u32 = undefined;

    for (entries, &names, &values) |entry, *name, *value| {
        value.* = entry.area_id;
        name.* = entry.group_name;
    }

    break :Id @Enum(u32, .exhaustive, &names, &values);
};

pub const Template = struct {
    area_id: u32,
    group_name: []const u8,

    pub inline fn getId(t: *const Template) Id {
        return @enumFromInt(t.area_id);
    }
};

const templates = @import("../templates.zig");
