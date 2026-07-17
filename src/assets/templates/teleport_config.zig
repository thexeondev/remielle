pub const entries: []const Template = @import("TeleportConfigTemplateTb");

pub const Template = struct {
    teleport_id: i32,
    client_visible: u1,
    unlock_condition: []const u8,
    teleport_name: []const u8,
    section_id: u32,
    transform_id: u32,
};

const templates = @import("../templates.zig");
