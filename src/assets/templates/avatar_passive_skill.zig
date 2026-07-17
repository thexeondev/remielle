pub const entries: []const Template = @import("AvatarPassiveSkillTemplateTb");

pub const Template = struct {
    skill_id: u32,
    avatar_id: u32,
    min_avatar_level: u32,
    min_passive_skill_level: u32,
    unlock_passive_skill_level: u32,
    propertys: []const Property,
    material_costs: []const ItemCount,
};

const Property = templates.Property;
const ItemCount = templates.ItemCount;

const templates = @import("../templates.zig");
