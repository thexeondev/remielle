pub const entries: []const Template = @import("SectionConfigTemplateTb");

pub const Id = Id: {
    @setEvalBranchQuota(entries.len);

    var names: [entries.len][]const u8 = undefined;
    var values: [entries.len]u32 = undefined;

    for (entries, &names, &values) |entry, *name, *value| {
        value.* = entry.section_id;
        name.* = if (entry.name.len != 0) entry.name else comptimePrint("{d}", .{entry.section_id});
    }

    break :Id @Enum(u32, .exhaustive, &names, &values);
};

pub fn byId(id: Id) ?*const Template {
    for (entries) |*entry| {
        if (entry.section_id == @intFromEnum(id))
            return entry;
    } else return null;
}

pub const Template = struct {
    section_id: u32,
    section_photo: []const u8,
    name: []const u8,
    default_transform: []const u8,
    section_name: []const u8,

    pub inline fn getId(t: *const Template) Id {
        return @enumFromInt(t.section_id);
    }
};

const comptimePrint = @import("std").fmt.comptimePrint;
