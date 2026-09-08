pub fn mutateHall(
    changes: logic.Changes.Subset(.{
        logic.Changes.GameMode,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.Hall,
    }),
) !void {
    if (changes.game_mode) |game_mode| switch (game_mode.*) {
        .hall => |hall| {
            properties.hall.section_id = hall.section_id;
            properties.hall.position = hall.position;
        },

        .training, .hadal_zone => {},
    };
}

const logic = @import("../../logic.zig");
const mutators = @import("../mutators.zig");
