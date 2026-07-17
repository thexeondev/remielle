pub const entries: []const Template = @import("AvatarSpecialAwakenTemplateTb");

pub const Template = struct {
    id: u32,
    avatar_id: u32,
    upgrade_item_ids: []const u32,
};
