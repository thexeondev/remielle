pub const entries: []const Template = @import("YorozuyaLevelTemplateTb");

pub const Template = struct {
    level: u8,
    experience: u32,
    reward_id: u32,
};
