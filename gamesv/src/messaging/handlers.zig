const remielle = @import("remielle");
const assets = remielle.assets;
const templates = assets.templates;
const protobuf = remielle.protobuf;
const pb = protobuf.main;

const log = std.log.scoped(.@"remielle-gamesv::messaging");

const namespaces: []const type = &.{
    @import("handlers/player.zig"),
    @import("handlers/avatar.zig"),
    @import("handlers/buddy.zig"),
    @import("handlers/item.zig"),
    @import("handlers/quest.zig"),
    @import("handlers/misc.zig"),
    @import("handlers/scene.zig"),
    @import("handlers/area_map.zig"),
    @import("handlers/hadal_zone.zig"),
    @import("handlers/quick_team.zig"),
};

const CmdId = CmdId: {
    var names: []const []const u8 = &.{};
    var values: []const u16 = &.{};

    for (namespaces) |ns| for (@typeInfo(ns).@"struct".decls) |decl| {
        const Fn = @TypeOf(@field(ns, decl.name));
        const Msg = MessageOf(Fn);

        values = values ++ .{protobuf.cmdId(Msg.Data) orelse continue};
        names = names ++ .{Msg.Data.pb_desc_name};
    };

    break :CmdId @Enum(u16, .exhaustive, names, @ptrCast(values));
};

pub const HandlerError = error{
    IllegalMessage,
} || Allocator.Error;

pub const ProcessError = error{
    DecodeFail,
} || Allocator.Error || messaging.SendError || messaging.notifiers.Error;

pub fn process(
    arena: Allocator,
    frame: *const Server.Frame,
    reader: *Io.Reader,
) ProcessError!void {
    @setEvalBranchQuota(1_000_000);

    const msg_header_bytes = reader.takeArray(messaging.Header.size) catch
        return error.DecodeFail;

    const msg_header = messaging.Header.decode(msg_header_bytes) catch
        return error.DecodeFail;

    const head_bytes = reader.take(msg_header.head_len) catch
        return error.DecodeFail;

    const head = messaging.decodePacketHead(head_bytes) orelse
        return error.DecodeFail;

    var xored_reader = frame.clients.getPtr(.xorpad, frame.target_index).wrapReader(reader, msg_header.body_len);

    const cmd_id = std.enums.fromInt(CmdId, msg_header.cmd_id) orelse {
        log.warn(
            "unhandled message with cmd_id {d} from {f}",
            .{ msg_header.cmd_id, frame.clients.get(.addr, frame.target_index) },
        );

        if (head.packet_id == 0) return;

        try messaging.sendDummy(
            frame.multi_conversation,
            frame.clients,
            frame.target_index,
            .ack(head.packet_id),
        );
        return;
    };

    switch (cmd_id) {
        inline else => |id| lookup: inline for (namespaces) |ns| {
            inline for (@typeInfo(ns).@"struct".decls) |decl| {
                const Fn = @TypeOf(@field(ns, decl.name));

                const InMessage = MessageOf(Fn);
                if (@intFromEnum(id) != protobuf.cmdId(InMessage.Data)) continue;

                const data = protobuf.decode(
                    .main,
                    InMessage.Data,
                    arena,
                    &xored_reader.interface,
                ) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => return error.DecodeFail,
                };

                const message: InMessage = .{ .data = &data };

                var changes: logic.Changes = .init;

                const Args = std.meta.ArgsTuple(Fn);
                var args: Args = undefined;

                const OutResponse = ResponseOf(Fn);
                var out_response: (OutResponse orelse void) = undefined;

                if (OutResponse != null) out_response = .{
                    .allocator = arena,
                    .data = null,
                };

                inline for (&args, @typeInfo(Args).@"struct".fields) |*arg, arg_info| {
                    switch (arg_info.type) {
                        InMessage => arg.* = message,
                        *const assets.Lookup => arg.* = frame.asset_lookup,
                        *const logic.Calendar => arg.* = frame.calendar,

                        logic.RealTimeClock => arg.* = .{
                            .time = frame.time,
                            .utc_offset = 3, // TODO: configuration field + cli option
                        },

                        else => |ArgType| {
                            switch (@typeInfo(ArgType)) {
                                .pointer => |pointer| switch (pointer.child) {
                                    @TypeOf(out_response) => {
                                        arg.* = &out_response;
                                        continue;
                                    },
                                    else => {},
                                },
                                else => {
                                    if (@hasField(ArgType, "pointers")) { // logic.Changes.Builder
                                        arg.* = .init(arena, &changes);
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
                                },
                            }

                            @compileError(decl.name ++ ": invalid argument type: " ++ @typeName(ArgType));
                        },
                    }
                }

                if (@call(.auto, @field(ns, decl.name), args)) {
                    // Success, run the pipeline
                    try logic.mutators.dispatchLogicChanges(frame, &changes);
                    try messaging.notifiers.notifyLogicChanges(arena, frame, &changes);
                } else |err| switch (@as(HandlerError, err)) {
                    error.IllegalMessage => {
                        // Send the response but don't run the pipeline
                        if (OutResponse) |Rsp| {
                            if (@hasField(Rsp.Data, "retcode")) {
                                if (out_response.data) |rsp|
                                    log.debug(
                                        InMessage.log_prefix ++ "handler failed with retcode {d}",
                                        .{rsp.retcode},
                                    );
                            }
                        }
                    },
                    else => |e| return e,
                }

                if (OutResponse) |Rsp| {
                    if (out_response.data) |out_message| {
                        if (protobuf.cmdId(Rsp.Data) != null) {
                            try messaging.send(
                                frame.multi_conversation,
                                frame.clients,
                                frame.target_index,
                                .ack(head.packet_id),
                                out_message,
                            );
                        } else {
                            try messaging.sendDummy(
                                frame.multi_conversation,
                                frame.clients,
                                frame.target_index,
                                .ack(head.packet_id),
                            );

                            log.debug(
                                InMessage.log_prefix ++ "response is not described; sent dummy to {f}",
                                .{frame.clients.get(.addr, frame.target_index)},
                            );
                        }
                    }
                }

                log.debug(
                    "processed message of type " ++ InMessage.Data.pb_desc_name ++ " from {f}",
                    .{frame.clients.get(.addr, frame.target_index)},
                );

                break :lookup;
            }
        } else comptime unreachable,
    }
}

pub fn Message(Msg: type) type {
    return struct {
        pub const Data = Msg;

        pub const log_prefix = "[" ++ Data.pb_desc_name ++ "] ";

        data: *const Data,
    };
}

pub fn Response(Msg: type) type {
    return *struct {
        pub const Data = Msg;

        allocator: Allocator,
        data: ?Data,

        pub inline fn set(response: *@This(), data: Data) void {
            std.debug.assert(response.data == null);
            response.data = data;
        }

        /// Shorthand for returning a failure.
        pub fn fail(response: *@This(), retcode: i32) error{IllegalMessage} {
            // TODO: `Retcode` enum
            response.set(.{ .retcode = retcode });
            return error.IllegalMessage;
        }
    };
}

fn MessageOf(comptime Fn: type) type {
    inline for (@typeInfo(Fn).@"fn".params) |param| {
        const Param = param.type.?;

        switch (@typeInfo(Param)) {
            .@"struct" => {},
            else => continue,
        }

        if (!@hasField(Param, "data")) continue;

        switch (@typeInfo(@FieldType(Param, "data"))) {
            .pointer => |pointer| if (Param == Message(pointer.child))
                return Param,
            else => continue,
        }
    } else comptime unreachable; // Handler has no `Message` argument.
}

fn ResponseOf(comptime Fn: type) ?type {
    inline for (@typeInfo(Fn).@"fn".params) |param| {
        const ParamIndirect = param.type.?;
        const Param = switch (@typeInfo(ParamIndirect)) {
            .pointer => |pointer| pointer.child,
            else => continue,
        };

        if (!@hasField(Param, "data")) continue;

        switch (@typeInfo(@FieldType(Param, "data"))) {
            .optional => |optional| if (ParamIndirect == Response(optional.child))
                return Param,
            else => continue,
        }
    } else return null;
}

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ClientVariables = Server.ClientVariables;

const Server = @import("../Server.zig");

const kcp = @import("../kcp.zig");
const logic = @import("../logic.zig");
const messaging = @import("../messaging.zig");

const rmio = @import("rmio");
const std = @import("std");
