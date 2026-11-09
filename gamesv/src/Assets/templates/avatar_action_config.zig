pub const entries: []const Template = @import("AvatarActionConfigTemplateTb");

pub const Template = struct {
    id: u32,
    avatar_id: u32,
    material_id: u32,
    form_ids: []const u32,
};
