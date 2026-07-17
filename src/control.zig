//! The server control protocol type definitions.

const std = @import("std");

pub const Operation = @import("control/Operation.zig");
pub const Event = @import("control/Event.zig");

/// The protocol version.
pub const Version = enum(u8) {
    pub const current: Version = .initial;

    initial = 0,
    _,
};

/// The network header of client to server messages.
pub const ClientHeader = extern struct {
    protocol_version: Version,
    operation_version: Operation.Version,
    operation_tag: Operation.Tag,
    userdata: u32,
};

/// The network header of server to client messages.
pub const ServerHeader = extern struct {
    protocol_version: Version,
    event_version: Event.Version,
    event_tag: Event.Tag,
    userdata: u32,
};

comptime {
    std.debug.assert(@sizeOf(ServerHeader) == @sizeOf(u64));
    std.debug.assert(@sizeOf(ClientHeader) == @sizeOf(u64));
}
