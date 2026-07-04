pub fn playerKick(
    operation: control.Operation(rmnet.Operation.PlayerKick),
    context: *const control.Context,
) !void {
    try context.sendEvent(rmnet.Event.Ack, .{});

    const server = context.server;

    const index: u32 = @intCast(server.uid_map.getIndex(operation.data.uid) orelse return);

    const reason: rmpb.main.PlayerKickReason = std.enums.fromInt(
        rmpb.main.PlayerKickReason,
        operation.data.reason,
    ) orelse @enumFromInt(0);

    const socket = context.sockets.get(app.SocketKind.game.toIndex());

    // TODO: this should be moved into `Server`.
    app.notifyPlayerKick(
        context.io,
        socket,
        context.server,
        context.time,
        index,
        reason,
    ) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {},
    };

    // TODO: this should be moved into `Server`.
    app.savePlayer(
        context.io,
        &context.server.resettable_arena,
        context.server.persistent,
        &context.server.properties,
        context.server.uid_map.keys()[index],
        index,
    );

    server.release(server.conv_map.keys()[index]);
}

const app = @import("../app.zig");
const control = @import("../control.zig");

const rmpb = @import("rmpb");
const rmnet = @import("rmnet");

const std = @import("std");
