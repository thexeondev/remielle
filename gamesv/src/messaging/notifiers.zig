const namespaces: []const type = &.{
    @import("notifiers/player_sync.zig"),
    @import("notifiers/scene.zig"),
};

pub const NotifierError = Allocator.Error;
pub const Error = NotifierError || messaging.SendError;

pub fn notifyLogicChanges(
    arena: Allocator,
    frame: *const Server.Frame,
    changes: *const logic.Changes,
) Error!void {
    inline for (namespaces) |ns| inline for (@typeInfo(ns).@"struct".decls) |decl| {
        const Fn = @TypeOf(@field(ns, decl.name));
        const Args = std.meta.ArgsTuple(Fn);

        var args: Args = undefined;
        var notify: NotifyOf(Fn) = .init(arena);

        call_notifier: {
            inline for (&args, @typeInfo(Args).@"struct".fields) |*arg, arg_info| {
                const ArgType = arg_info.type;

                if (ArgType == *NotifyOf(Fn)) {
                    arg.* = &notify;
                    continue;
                }

                if (ArgType == *const Assets.Lookup) {
                    arg.* = frame.asset_lookup;
                    continue;
                }

                if (ArgType == logic.RealTimeClock) {
                    arg.* = .{
                        .time = frame.time,
                        .utc_offset = 3, // TODO: configuration field + cli option
                    };
                    continue;
                }

                if (ArgType == *const logic.Calendar) {
                    arg.* = frame.calendar;
                    continue;
                }

                if (@hasField(ArgType, logic.Changes.subset_marker_name)) {
                    arg.* = changes.extract(ArgType) orelse break :call_notifier;
                    continue;
                }

                // Accepting mutable properties is intentionally not allowed.
                if (@hasField(ArgType, logic.Properties.immutable_subset_marker_name)) {
                    arg.* = logic.Properties.extractFor(
                        frame.properties,
                        ArgType,
                        frame.target_index,
                    );
                    continue;
                }

                @compileError(decl.name ++ ": invalid argument type: " ++ @typeName(ArgType));
            }

            @call(.auto, @field(ns, decl.name), args) catch |err| switch (@as(Error, err)) {
                else => |e| return e,
            };

            const notifies = switch (notify.to_send) {
                .none => break :call_notifier,
                .one => |*one| one[0..1],
                .many => |many| many,
            };

            for (notifies) |message| try messaging.send(
                frame.multi_conversation,
                frame.clients,
                frame.target_index,
                .notify,
                message,
            );
        }
    };
}

pub fn Notify(comptime OutNotify: type) type {
    return *struct {
        const Out = @This();

        pub const Notify = OutNotify;

        allocator: Allocator,
        to_send: union(enum) {
            none: void,
            one: OutNotify,
            many: []const OutNotify,
        },

        pub fn init(allocator: Allocator) Out {
            return .{ .allocator = allocator, .to_send = .none };
        }

        pub fn one(out: *Out, notify: OutNotify) void {
            std.debug.assert(out.to_send == .none);
            out.to_send = .{ .one = notify };
        }

        pub fn many(out: *Out, notifies: []const OutNotify) void {
            std.debug.assert(out.to_send == .none);
            out.to_send = .{ .many = notifies };
        }
    };
}

fn NotifyOf(Fn: type) type {
    var Type: ?type = null;

    inline for (@typeInfo(Fn).@"fn".params) |param| {
        switch (@typeInfo(param.type.?)) {
            .pointer => |pointer| if (@hasDecl(pointer.child, "Notify")) {
                if (Type != null) @compileError("notifiers: multiple notifies are not allowed");
                Type = pointer.child;
            },
            else => continue,
        }
    }

    return Type orelse @compileError("notifiers: not a single output defined");
}

const Allocator = std.mem.Allocator;

const Server = @import("../Server.zig");
const Assets = @import("../Assets.zig");
const logic = @import("../logic.zig");
const messaging = @import("../messaging.zig");

const std = @import("std");
