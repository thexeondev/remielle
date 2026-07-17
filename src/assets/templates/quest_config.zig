pub const entries: []const Template = @import("QuestConfigTemplateTb");

pub const Template = struct {
    quest_id: u32,
    quest_name: []const u8,
    quest_type: u32,
};
