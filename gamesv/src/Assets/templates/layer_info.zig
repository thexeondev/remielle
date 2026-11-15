pub const entries: []const Template = @import("LayerInfoTemplateTb");

pub const Template = struct {
    layer_id: u32,
    layer_room_ids: []const u32 = &.{},
    layer_items: []const u32 = &.{},
    weather_list: []const []const u8 = &.{},
};
