const std = @import("std");
const Allocator = std.mem.Allocator;

pub const templates = @import("Assets/templates.zig");
pub const graphs = @import("Assets/graphs.zig");

pub const Lookup = struct {
    main_city_object_map: templates.main_city_object.Map,

    pub fn init(gpa: Allocator) !Lookup {
        return .{
            .main_city_object_map = try templates.main_city_object.createMap(gpa),
        };
    }

    pub fn deinit(l: *Lookup, gpa: Allocator) void {
        l.main_city_object_map.deinit(gpa);
    }
};
