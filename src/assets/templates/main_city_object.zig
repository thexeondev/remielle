pub const Map = std.array_hash_map.Auto(u32, void);

const bytes align(@alignOf(u32)) = @embedFile("main_city_object_template_tb.remi").*;

const header: *const Header = @ptrCast(&bytes);

pub const tag_ids: []const u32 = @ptrCast(
    bytes[header.tag_ids_offset..][0 .. header.count * @sizeOf(u32)],
);

pub const default_interact_ids: [*]const u32 = @ptrCast(bytes[header.default_interact_ids_offset..]);

pub const interact_names: [*]const String = @ptrCast(bytes[header.interact_names_offset..]);

pub const string_table: [*]const u8 = bytes[header.string_table_offset..];

const Header = extern struct {
    count: u32,
    tag_ids_offset: u32,
    default_interact_ids_offset: u32,
    interact_names_offset: u32,
    string_table_offset: u32,
};

pub fn createMap(gpa: std.mem.Allocator) !Map {
    var map: Map = .empty;
    try map.reinit(gpa, tag_ids, &.{});
    return map;
}

pub const String = enum(u32) {
    empty = std.math.maxInt(u32),
    _,
};

pub fn getString(string: String) [:0]const u8 {
    return switch (string) {
        .empty => "",
        _ => |index| std.mem.span(@as(
            [*:0]const u8,
            @ptrCast(string_table[@intFromEnum(index)..]),
        )),
    };
}

const std = @import("std");
