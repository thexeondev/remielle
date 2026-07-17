pub const entries: []const Template = @import("PostGirlConfigTemplateTb");

pub const Id = Id: {
    @setEvalBranchQuota(entries.len);

    var names: [entries.len][]const u8 = undefined;
    var values: [entries.len]u32 = undefined;

    for (entries, &names, &values) |entry, *name, *value| {
        value.* = entry.id;
        name.* = entry.name;
    }

    break :Id @Enum(u32, .exhaustive, &names, &values);
};

pub const Template = struct {
    id: u32,
    name: []const u8,
    unlock_condition: []const u8,

    pub inline fn getId(t: *const Template) Id {
        return @enumFromInt(t.id);
    }
};
