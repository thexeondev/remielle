pub const entries: []const Template = @import("PostGirlConfigTemplateTb");

pub const Template = struct {
    id: u32,
    name: []const u8,
    unlock_condition: []const u8,
};
