pub const mtu: usize = 1200;

const namespaces: []const type = &.{
    @import("control/player.zig"),
    @import("control/calendar.zig"),
};

pub fn Operation(comptime T: type) type {
    if (@hasDecl(T, "trailing")) @compileError("use `ExtendedOperation` instead");

    return struct {
        pub const Data = T;

        data: *const Data,
    };
}

pub fn ExtendedOperation(comptime T: type) type {
    return struct {
        pub const Data = T;

        operation: *const Data,
        entries: []const Data.trailing.Entry,
    };
}

// TODO: decide on how to pass this in.
pub const Context = struct {
    io: Io,
    time: Io.Timestamp,
    server: *Server,
    from: *const net.IpAddress,
    userdata: u32,

    pub fn sendEvent(context: *const Context, comptime Event: type, event: Event) !void {
        const message: rmnet.Event.Message(Event) = .init(context.userdata, event);

        const socket = context.server.sockets.get(Server.Socket.control.toIndex());
        try socket.send(context.io, context.from, @ptrCast(&message));
    }
};

pub fn process(
    io: Io,
    current_time: Io.Timestamp,
    server: *Server,
    from: *const net.IpAddress,
    data: []align(@alignOf(u64)) u8,
) !void {
    if (data.len < @sizeOf(rmnet.ClientHeader))
        return error.InvalidPacket;

    const socket = server.sockets.get(Server.Socket.control.toIndex());

    const header: *rmnet.ClientHeader = @ptrCast(data[0..@sizeOf(rmnet.ClientHeader)]);
    if (header.protocol_version != rmnet.Version.current)
        return send(rmnet.Event.Nak, io, socket, from, header.userdata, .{
            .reason = .protocol_version_mismatch,
            .extra = @intFromEnum(rmnet.Version.current),
        });

    switch (header.operation_tag) {
        _ => return send(rmnet.Event.Nak, io, socket, from, header.userdata, .{
            .reason = .unknown_operation_tag,
            .extra = 0,
        }),
        .nop => {
            if (header.operation_version != rmnet.Operation.Nop.version)
                return send(rmnet.Event.Nak, io, socket, from, header.userdata, .{
                    .reason = .operation_version_mismatch,
                    .extra = rmnet.Operation.Nop.version,
                });

            try send(rmnet.Event.Ack, io, socket, from, header.userdata, .{});
        },
        inline else => |operation_tag| lookup: inline for (namespaces) |ns| {
            inline for (@typeInfo(ns).@"struct".decls) |decl| {
                const fn_info = switch (@typeInfo(@TypeOf(@field(ns, decl.name)))) {
                    .@"fn" => |fn_info| fn_info,
                    else => continue,
                };

                // The signature should look like this:
                // fn(Operation(T), *const Context)
                const OperationParam = fn_info.params[0].type.?;

                if (OperationParam.Data.tag != operation_tag)
                    continue;

                if (header.operation_version != rmnet.Operation.Nop.version)
                    return send(rmnet.Event.Nak, io, socket, from, header.userdata, .{
                        .reason = .operation_version_mismatch,
                        .extra = OperationParam.Data.version,
                    });

                if (@hasField(OperationParam, "entries")) {
                    // ExtendedOperation.

                    const BaseMessage = rmnet.Operation.Message(OperationParam.Data);

                    if (data.len < @sizeOf(BaseMessage))
                        return error.InvalidPacket;

                    const base: *const BaseMessage = @ptrCast(data[0..@sizeOf(BaseMessage)]);
                    const Entry = OperationParam.Data.trailing.Entry;

                    const entries_base: [*]const Entry = @ptrFromInt(std.mem.alignForward(
                        usize,
                        @intFromPtr(base) + @sizeOf(BaseMessage),
                        @alignOf(Entry),
                    ));

                    const entries_count = @field(
                        base.operation,
                        OperationParam.Data.trailing.entries_count_field,
                    );

                    const entries_end = @intFromPtr(entries_base + entries_count);
                    if (entries_end - @intFromPtr(data.ptr) != data.len)
                        return error.InvalidPacket;

                    try @field(ns, decl.name)(
                        .{
                            .operation = &base.operation,
                            .entries = entries_base[0..entries_count],
                        },
                        &.{
                            .io = io,
                            .time = current_time,
                            .server = server,
                            .from = from,
                            .userdata = header.userdata,
                        },
                    );

                    break :lookup;
                } else {
                    const ExpectedMessage = rmnet.Operation.Message(OperationParam.Data);

                    if (data.len != @sizeOf(ExpectedMessage))
                        return error.InvalidPacket;

                    const message: *ExpectedMessage = @ptrCast(data);
                    try @field(ns, decl.name)(.{ .data = &message.operation }, &.{
                        .io = io,
                        .time = current_time,
                        .server = server,
                        .from = from,
                        .userdata = header.userdata,
                    });

                    break :lookup;
                }
            }
        },
    }
}

fn send(
    comptime Event: type,
    io: Io,
    socket: net.Socket,
    destination: *const net.IpAddress,
    userdata: u32,
    event: Event,
) !void {
    const message: rmnet.Event.Message(Event) = .init(userdata, event);
    try socket.send(io, destination, @ptrCast(&message));
}

const Io = std.Io;
const net = std.Io.net;

const app = @import("app.zig");
const Server = @import("Server.zig");

const rmnet = @import("rmnet");
const rmpb = @import("rmpb");
const rmio = @import("rmio");
const std = @import("std");
