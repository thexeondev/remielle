pub const entries: []const Template = @import("ZoneInfoTemplateTb");

pub const Template = struct {
    zone_id: u32,
    name: []const u8,
    layer_id: u32,
    layer_index: u32,
    group_id: u32,
    zone_group_id: u32,
    entrance_id: u32,
    time_period_list: []const []const u8,
};
