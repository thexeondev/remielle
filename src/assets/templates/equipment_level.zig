pub const entries: []const Template = @import("EquipmentLevelTemplateTb");

pub const Template = struct {
    rarity: u32,
    level: u32,
    property_rate: i32,
};
