const Changes = @This();

const std = @import("std");

const remielle = @import("remielle");
const templates = remielle.assets.templates;

const Server = @import("../Server.zig");
const Properties = @import("Properties.zig");
const packers = @import("../messaging/packers.zig");
const AvatarSlot = packers.AvatarSlot;

pub const init: Changes = .{};

pub const subset_marker_name = "logic_changes_subset_marker";

pub fn Subset(comptime types: anytype) type {
    // Add a ZST field as a marker
    var field_types: [types.len + 1]type = undefined;
    field_types[0] = void;

    var field_names: [types.len + 1][]const u8 = undefined;
    field_names[0] = subset_marker_name;

    const changes_info = @typeInfo(Changes).@"struct";

    for (types, field_types[1..], field_names[1..]) |C, *SubsetType, *subset_field_name| {
        search: for (
            changes_info.field_types,
            changes_info.field_names,
        ) |ChangesType, changes_field_name| {
            if (ChangesType == ?C) {
                SubsetType.* = ?*const C;
                subset_field_name.* = changes_field_name;
                break :search;
            } else if (ChangesType == []const C) {
                SubsetType.* = ChangesType;
                subset_field_name.* = changes_field_name;
                break :search;
            }
        } else @compileError("Invalid change type: " ++ @typeName(C));
    }

    return @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
}

pub fn Builder(comptime types: anytype) type {
    return struct {
        const Pointers = pointers: {
            const changes_info = @typeInfo(Changes).@"struct";

            var field_types: [types.len]type = undefined;
            var field_names: [types.len][]const u8 = undefined;

            for (types, &field_types, &field_names) |C, *field_type, *field_name| {
                search: for (
                    changes_info.field_types,
                    changes_info.field_names,
                ) |ChangeType, change_name| {
                    if (ChangeType == ?C or ChangeType == []const C) {
                        field_type.* = *ChangeType;
                        field_name.* = change_name;
                        break :search;
                    }
                } else @compileError("Invalid change type: " ++ @typeName(C));
            }

            break :pointers @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
        };

        allocator: std.mem.Allocator,
        pointers: Pointers,

        pub fn init(allocator: std.mem.Allocator, changes: *Changes) @This() {
            var pointers: Pointers = undefined;

            inline for (@typeInfo(Pointers).@"struct".field_names) |field_name|
                @field(pointers, field_name) = &@field(changes, field_name);

            return .{ .allocator = allocator, .pointers = pointers };
        }

        pub inline fn insert(builder: *const @This(), change: anytype) void {
            const Change = @TypeOf(change);
            const changes_info = @typeInfo(Changes).@"struct";

            switch (@typeInfo(Change)) {
                .pointer => |pointer| {
                    inline for (
                        changes_info.field_names,
                        changes_info.field_types,
                    ) |field_name, FieldType| {
                        if (FieldType == []const pointer.child) {
                            const ptr = @field(builder.pointers, field_name);
                            std.debug.assert(ptr.*.len == 0);
                            ptr.* = change;
                            break;
                        }
                    } else @compileError("invalid change type: " ++ @typeName(Change));
                },
                else => {
                    inline for (
                        changes_info.field_names,
                        changes_info.field_types,
                    ) |field_name, FieldType| {
                        if (FieldType == ?Change) {
                            const ptr = @field(builder.pointers, field_name);
                            std.debug.assert(ptr.* == null);
                            ptr.* = change;
                            break;
                        }
                    } else @compileError("invalid change type: " ++ @typeName(Change));
                },
            }
        }
    };
}

/// Returns `null` if not a single field is active.
pub fn extract(logic_changes: *const Changes, comptime Sub: type) ?Sub {
    var subset: Sub = undefined;
    var any_fulfilled: u1 = 0;

    const sub_info = @typeInfo(Sub).@"struct";

    inline for (
        sub_info.field_names,
        sub_info.field_types,
    ) |field_name, FieldType| {
        if (FieldType == void) continue;

        switch (@typeInfo(FieldType)) {
            .pointer => {
                @field(subset, field_name) = @field(logic_changes, field_name);
                any_fulfilled |= @intFromBool(@field(logic_changes, field_name).len != 0);
            },
            .optional => {
                @field(subset, field_name) = if (@field(logic_changes, field_name)) |*change|
                    change
                else
                    null;
                any_fulfilled |= @intFromBool(@field(logic_changes, field_name) != null);
            },
            else => comptime unreachable,
        }
    }

    return if (any_fulfilled != 0) subset else null;
}
