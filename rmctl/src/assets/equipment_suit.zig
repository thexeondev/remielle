pub const entries: []const Template = @import("EquipmentSuitTemplateTb");

pub const Template = struct {
    id: u32,
    primary_condition: u32,
    primary_suit_ability: u32,
    secondary_condition: u32,
    secondary_suit_ability: u32,
    primary_suit_propertys: []const Property,
};

pub const Property = struct {
    property: u32,
    value: i32,
};
