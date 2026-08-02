pub fn mutateAvatar(
    changes: logic.Changes.Subset(.{
        logic.Changes.Avatar,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.Avatar,
    }),
) !void {
    for (changes.avatars) |change| {
        const index = properties.avatar.indexes.get(change.id).?;

        properties.avatar.meta[index] = change.meta;
        properties.avatar.weapon_uids[index] = change.weapon_uid;
        properties.avatar.equipment_uids[index] = change.equipment_uids;
        properties.avatar.awake_material_counts[index] = change.awake_material_count;
    }
}

pub fn createAvatar(
    changes: logic.Changes.Subset(.{
        logic.Changes.NewAvatar,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.Avatar,
    }),
) !void {
    for (changes.new_avatars) |change| {
        const i = properties.avatar.count();

        logic.Properties.addDefaultAvatar(properties.avatar, change.id, i);
    }
}

const logic = @import("../../logic.zig");
const mutators = @import("../mutators.zig");
