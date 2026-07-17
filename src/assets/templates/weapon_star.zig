pub const entries: []const Template = @import("WeaponStarTemplateTb");

pub const Template = struct {
    rarity: u32,
    star: u32,
    min_level: u32,
    max_level: u32,
    star_rate: i32,
    rand_rate: i32,
};
