pub const entries: []const Template = @import("AvatarLevelAdvanceTemplateTb");

pub const Template = struct {
    avatar_id: u32,
    id: u32,
    min_level: u32,
    max_level: u32,
    hp_max: i32,
    attack: i32,
    defence: i32,
    promotion_costs: []const ItemCount,
};

const ItemCount = templates.ItemCount;

const templates = @import("../templates.zig");
