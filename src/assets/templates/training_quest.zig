pub const entries: []const Template = @import("TrainingQuestTemplateTb");

pub const Id = enum(u32) {
    free_training = entries[0].id,
    _,

    pub fn getBattleEventId(id: Id) u32 {
        return search: {
            for (entries) |entry| {
                if (entry.getId() == id)
                    break :search entry.battle_event_id;
            } else break :search entries[0].battle_event_id; // fallback
        };
    }
};

pub const Template = struct {
    id: u32,
    training_type: u32,
    battle_event_id: u32,
    special_training_name: []const u8,
    special_training_icon: []const u8,

    pub inline fn getId(t: *const Template) Id {
        return @enumFromInt(t.id);
    }
};
