pub const avatar_base = @import("templates/avatar_base.zig");
pub const buddy_base = @import("templates/buddy_base.zig");
pub const avatar_skin_base = @import("templates/avatar_skin_base.zig");
pub const unlock_config = @import("templates/unlock_config.zig");
pub const post_girl_config = @import("templates/post_girl_config.zig");
pub const section_config = @import("templates/section_config.zig");
pub const yorozuya_level = @import("templates/yorozuya_level.zig");
pub const training_quest = @import("templates/training_quest.zig");
pub const weapon = @import("templates/weapon.zig");
pub const equipment = @import("templates/equipment.zig");
pub const urban_area_map = @import("templates/urban_area_map.zig");
pub const urban_area_map_group = @import("templates/urban_area_map_group.zig");
pub const teleport_config = @import("templates/teleport_config.zig");
pub const main_city_object = @import("templates/main_city_object.zig");
pub const zone_info = @import("templates/zone_info.zig");
pub const quest_config = @import("templates/quest_config.zig");
pub const hadal_zone_quest = @import("templates/hadal_zone_quest.zig");
pub const avatar_level_advance = @import("templates/avatar_level_advance.zig");
pub const avatar_passive_skill = @import("templates/avatar_passive_skill.zig");
pub const weapon_level = @import("templates/weapon_level.zig");
pub const weapon_star = @import("templates/weapon_star.zig");
pub const equipment_level = @import("templates/equipment_level.zig");
pub const equipment_suit = @import("templates/equipment_suit.zig");
pub const avatar_battle = @import("templates/avatar_battle.zig");
pub const avatar_special_awaken = @import("templates/avatar_special_awaken.zig");

pub const Property = struct {
    property: u32,
    value: i32,
};

pub const ItemCount = struct {
    item_id: u32,
    number: u32,
};
