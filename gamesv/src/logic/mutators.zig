pub const Error = error{};

const namespaces: []const type = &.{
    @import("mutators/quick_team.zig"),
};

pub fn dispatchLogicChanges(frame: *const Server.Frame, changes: *const logic.Changes) Error!void {
    inline for (namespaces) |ns| inline for (@typeInfo(ns).@"struct".decl_names) |decl_name| {
        const Fn = @TypeOf(@field(ns, decl_name));
        const Args = std.meta.ArgsTuple(Fn);
        var args: Args = undefined;

        call_mutator: {
            inline for (&args, @typeInfo(Args).@"struct".field_types) |*arg, ArgType| {
                if (@hasField(ArgType, logic.Changes.subset_marker_name)) {
                    arg.* = changes.extract(ArgType) orelse break :call_mutator;
                    continue;
                }

                if (@hasField(ArgType, logic.Properties.immutable_subset_marker_name) or
                    @hasField(ArgType, logic.Properties.mutable_subset_marker_name))
                {
                    arg.* = logic.Properties.extractFor(
                        frame.properties,
                        ArgType,
                        frame.target_index,
                    );
                    continue;
                }

                @compileError(decl_name ++ ": invalid argument type: " ++ @typeName(ArgType));
            }

            @call(.auto, @field(ns, decl_name), args) catch |err| switch (@as(Error, err)) {
                else => |e| return e,
            };
        }
    };
}

const Server = @import("../Server.zig");
const logic = @import("../logic.zig");

const std = @import("std");
