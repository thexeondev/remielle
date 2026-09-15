const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const remielle = @import("remielle");
const assets = remielle.assets;
const templates = remielle.assets.templates;
const protobuf = remielle.protobuf;
const pb = protobuf.main;

const logic = @import("../logic.zig");
const messaging = @import("../messaging.zig");

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

pub const HandlerError = error{
    IllegalMessage,
    DecodeFail,
} || Allocator.Error || messaging.SendError;

const HandlerFn = fn (scope: *Scope) Scope.Error!void;

const client_server_cmd_max = 10_000;

const handlers: [client_server_cmd_max]?*const HandlerFn = handlers: {
    var array: [client_server_cmd_max]?*const HandlerFn = @splat(null);

    @setEvalBranchQuota(namespaces.len);
    for (namespaces) |namespace| {
        const decl_names = @typeInfo(namespace).@"struct".decl_names;

        @setEvalBranchQuota(decl_names.len);
        for (decl_names) |decl_name| {
            if (!@hasDecl(protobuf.main_desc, decl_name))
                continue;

            const message_desc = @field(protobuf.main_desc, decl_name);
            const message_cmd_id = message_desc.cmd_id;

            const handlerFn: *const HandlerFn = &@field(namespace, decl_name);
            assert(array[message_cmd_id] == null); // Duplicated handler.
            array[message_cmd_id] = handlerFn;
        }
    }

    break :handlers array;
};

fn getHandler(cmd_id: u16) ?*const HandlerFn {
    if (cmd_id >= handlers.len) return null;
    return handlers[cmd_id];
}

pub fn process(
    arena: Allocator,
    time: Io.Timestamp,
    sink: *const messaging.Sink,
    properties: *logic.Properties,
    asset_lookup: *const assets.Lookup,
    calendar: *const logic.Calendar,
    command: *const remielle.protocol.Command,
) HandlerError!void {
    var head_reader: Io.Reader = .fixed(command.head);
    const head = protobuf.decode(.stable, protobuf.stable.PacketHead, .failing, &head_reader) catch
        return error.DecodeFail;

    const handlerFn = getHandler(command.id) orelse {
        log.warn("unhandled message with cmd_id {d}", .{command.id});

        if (head.packet_id != 0) {
            try messaging.sendDummy(sink, .ack(head.packet_id));
        }

        return;
    };

    var body_reader: Io.Reader = .fixed(command.body);
    var scope: Scope = .{
        .asset_lookup = asset_lookup,
        .properties = properties,
        .calendar = calendar,
        .clock = .{
            .time = time,
            .utc_offset = 3, // TODO: configuration field + cli option
        },
        .source = .{
            .allocator = arena,
            .reader = &body_reader,
        },
        .sink = .{
            .allocator = arena,
            .inner = sink,
            .ack_packet_id = head.packet_id,
        },
    };

    try handlerFn(&scope);

    log.debug("processed message with id {d}", .{command.id});
}

pub const Scope = struct {
    asset_lookup: *const assets.Lookup,
    properties: *logic.Properties,
    calendar: *const logic.Calendar,
    clock: logic.RealTimeClock,
    source: Source,
    sink: Sink,

    pub const Error = HandlerError;
};

pub const Source = struct {
    allocator: Allocator,
    reader: *Io.Reader,

    pub const Error = Allocator.Error || error{DecodeFail};

    pub fn take(source: *const Source, comptime Message: type) Source.Error!Message {
        return protobuf.decode(
            .main,
            Message,
            source.allocator,
            source.reader,
        ) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return error.DecodeFail,
        };
    }
};

pub const Sink = struct {
    inner: *const messaging.Sink,
    ack_packet_id: u32,
    allocator: Allocator,

    pub fn notify(
        sink: Sink,
        comptime Notify: type,
        message: Notify,
    ) messaging.SendError!void {
        try messaging.send(
            sink.inner,
            .notify,
            message,
        );
    }

    pub fn respond(
        sink: *Sink,
        comptime Response: type,
        message: Response,
    ) messaging.SendError!void {
        if (protobuf.cmdId(Response) != null) {
            try messaging.send(
                sink.inner,
                .ack(sink.ack_packet_id),
                message,
            );
        } else {
            try messaging.sendDummy(
                sink.inner,
                .ack(sink.ack_packet_id),
            );
        }
    }
};
