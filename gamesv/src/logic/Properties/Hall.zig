const Hall = @This();
const remielle = @import("remielle");
const LimitedString = remielle.mem.LimitedString;

const Assets = @import("../../Assets.zig");
const templates = Assets.templates;

section_id: templates.section_config.Id,
position: Position,

pub const init: Hall = .{
    .section_id = .MainCity_Street,
    .position = .init,
};

pub const Position = union(enum) {
    id: Id,
    transform: Transform,

    pub const init: Position = .{
        .id = .empty,
    };

    pub const Id = LimitedString(127);

    pub const Transform = struct {
        pub const vector_size = 3;

        position: [vector_size]f64,
        rotation: [vector_size]f64,

        pub fn fromVectors(position: []const f64, rotation: []const f64) ?Transform {
            if (position.len != vector_size or rotation.len != vector_size)
                return null;

            return .{
                .position = position[0..vector_size].*,
                .rotation = rotation[0..vector_size].*,
            };
        }
    };

    pub fn fromId(string: []const u8) ?Position {
        return .{ .id = Id.fromSlice(string) catch
            return null };
    }

    pub fn fromVectors(position: []const f64, rotation: []const f64) ?Position {
        return .{ .transform = Transform.fromVectors(
            position,
            rotation,
        ) orelse return null };
    }
};
