pub const entries: []const Template = @import("BuddyBaseTemplateTb");

pub const assisting_buddy = entries[0];

pub const Id = Id: {
    @setEvalBranchQuota(entries.len * 1000);
    var names: [entries.len][]const u8 = undefined;
    var values: [entries.len]u32 = undefined;

    for (entries, &names, &values) |entry, *name, *value| {
        value.* = entry.id;
        name.* = std.fmt.comptimePrint("buddy_{d}", .{entry.id});
    }

    break :Id @Enum(u32, .exhaustive, &names, &values);
};

pub const Template = struct {
    id: u32,

    pub inline fn getId(t: *const Template) Id {
        return @enumFromInt(t.id);
    }
};

const std = @import("std");
