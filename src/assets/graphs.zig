pub const Event = packed struct {
    actions_begin: u32,
    actions_end: u32,
};

pub const Action = extern struct {
    tag: Tag,
    data: Data,

    const Tag = enum(u32) {
        create_npc = 1,
        change_interact = 2,
        switch_section = 3,
        open_ui = 4,
    };

    const Data = extern union {
        create_npc: CreateNpc,
        change_interact: ExtraIndex,
        switch_section: ExtraIndex,
        open_ui: ExtraIndex,
    };

    pub const ExtraIndex = enum(u32) {
        _,

        pub inline fn toIndex(ei: ExtraIndex) u32 {
            return @intFromEnum(ei);
        }
    };

    pub const CreateNpc = extern struct {
        tag_id: u32,
    };

    pub const ChangeInteract = extern struct {
        tag_id: u32,
        interact_id: u32,
    };

    const SwitchSection = extern struct {
        section_id: u32,
        transform_id: String,
        camera_x: u32,
        camera_y: u32,
    };

    const OpenUi = packed struct {
        ui: String,
        store_template_id: u32,
    };
};

pub const main_city = struct {
    const bytes align(@alignOf(u32)) = @embedFile("main_city.remi").*;

    const header: *const Header = @ptrCast(&bytes);

    pub const section_ids: []const u32 = @ptrCast(@alignCast(
        bytes[header.sections_offset..][0 .. header.section_count * @sizeOf(u32)],
    ));

    pub const events: [*]const Event = @ptrCast(@alignCast(bytes[header.events_offset..].ptr));

    pub const actions: [*]const Action = @ptrCast(@alignCast(bytes[header.actions_offset..].ptr));

    pub const change_interact: [*]const Action.ChangeInteract = @ptrCast(@alignCast(bytes[header.change_interact_offset..].ptr));

    const Header = extern struct {
        section_count: u32,
        sections_offset: u32,
        events_offset: u32,
        actions_offset: u32,
        change_interact_offset: u32,
    };
};

pub const String = enum(u32) {
    empty = std.math.maxInt(u32),
    _,
};

pub const interacts = struct {
    const bytes align(@alignOf(u32)) = @embedFile("interacts.remi").*;

    const header: *const Header = @ptrCast(&bytes);

    pub const ids: []const u32 = @ptrCast(@alignCast(
        bytes[header.ids_offset..][0 .. header.count * @sizeOf(u32)],
    ));

    pub const events: [*]const Event = @ptrCast(@alignCast(bytes[header.events_offset..].ptr));

    pub const actions: [*]const Action = @ptrCast(@alignCast(bytes[header.actions_offset..].ptr));

    pub const change_interact: [*]const Action.ChangeInteract = @ptrCast(@alignCast(
        bytes[header.change_interact_offset..].ptr,
    ));

    pub const switch_section: [*]const Action.SwitchSection = @ptrCast(@alignCast(bytes[header.switch_section_offset..].ptr));

    pub const open_ui: [*]const Action.OpenUi = @ptrCast(@alignCast(bytes[header.open_ui_offset..].ptr));

    pub const string_table: [*]const u8 = @ptrCast(@alignCast(bytes[header.string_table_offset..].ptr));

    const Header = extern struct {
        count: u32,
        ids_offset: u32,
        events_offset: u32,
        actions_offset: u32,
        change_interact_offset: u32,
        switch_section_offset: u32,
        open_ui_offset: u32,
        string_table_offset: u32,
    };

    pub fn getString(string: String) [:0]const u8 {
        return switch (string) {
            .empty => "",
            _ => |index| std.mem.span(@as(
                [*:0]const u8,
                @ptrCast(interacts.string_table[@intFromEnum(index)..]),
            )),
        };
    }
};

const std = @import("std");
const Graphs = @This();
