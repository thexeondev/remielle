pub const entries: []const Template = @import("AvatarBaseTemplateTb");

pub const Id = Id: {
    @setEvalBranchQuota(entries.len * entries.len * entries.len);

    var exist_set_buf: [entries.len][:0]const u8 = undefined;
    var exist_set_count: usize = 0;

    var names: [entries.len][:0]const u8 = undefined;
    var values: [entries.len]u32 = undefined;

    for (entries, &names, &values) |entry, *name, *value| {
        value.* = entry.id;

        // Check if it already exists. Annoying, because they have duplicated characters.
        for (exist_set_buf[0..exist_set_count]) |existing_name| {
            if (std.mem.eql(u8, existing_name, entry.audio_event_replace_param)) {
                name.* = comptimePrint("{s}_{d}", .{ entry.audio_event_replace_param, entry.id });
                break;
            }
        } else {
            exist_set_buf[exist_set_count] = entry.audio_event_replace_param;
            exist_set_count += 1;

            name.* = entry.audio_event_replace_param;
        }
    }

    break :Id @Enum(u32, .exhaustive, &names, &values);
};

pub const Template = struct {
    id: u32,
    camp: u32,
    gender: u32,
    name: []const u8,
    code_name: []const u8,
    full_name: []const u8,
    audio_event_replace_param: [:0]const u8,

    pub inline fn getId(t: *const Template) Id {
        return @enumFromInt(t.id);
    }
};

const comptimePrint = std.fmt.comptimePrint;
const std = @import("std");
