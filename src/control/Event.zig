const remielle = @import("../remielle.zig");
const ServerHeader = remielle.control.ServerHeader;

pub const Version = u8;

pub const Tag = enum(u16) {
    ack = 0,
    nak = 1,
    _,
};

pub const Ack = extern struct {
    pub const tag: Tag = .ack;
    pub const version: Version = 0;
};

pub const Nak = extern struct {
    pub const tag: Tag = .nak;
    pub const version: Version = 0;

    pub const Reason = enum(u32) {
        protocol_version_mismatch = 1,
        operation_version_mismatch = 2, // extra: server operation version
        unknown_operation_tag = 3,
        invalid_parameter = 4,
        no_entry = 5,
        no_space_left = 6, // extra: amount of space left
        _,
    };

    reason: Reason,
    extra: u32,
};

pub fn Message(comptime Event: type) type {
    return extern struct {
        header: ServerHeader,
        event: Event,

        pub fn init(userdata: u32, event: Event) @This() {
            return .{
                .header = .{
                    .protocol_version = .current,
                    .event_version = Event.version,
                    .event_tag = Event.tag,
                    .userdata = userdata,
                },
                .event = event,
            };
        }
    };
}
