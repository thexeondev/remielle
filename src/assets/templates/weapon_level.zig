pub const entries: []const Template = @import("WeaponLevelTemplateTb");

pub const Template = struct {
    rarity: u32,
    level: u32,
    rate: i32,
    exp: u32,
};
