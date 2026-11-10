pub const max_room_count = 2;
pub const max_avatar_per_room_count = 3;
pub const max_buddy_per_room_count = 1;

zone_id: u32,
layer_index: u32,
room_index: u32,
layer_item_id: u32,
avatar_id_list: [max_room_count * max_avatar_per_room_count]u32,
buddy_id_list: [max_room_count * max_buddy_per_room_count]u32,

pub const init: HadalZone = .{
    .zone_id = 0,
    .layer_index = 0,
    .room_index = 0,
    .layer_item_id = 0,
    .avatar_id_list = @splat(0),
    .buddy_id_list = @splat(0),
};

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const rmmem = @import("rmmem");

const HadalZone = @This();
