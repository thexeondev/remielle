pub const Version = u8;

pub const Tag = enum(u16) {
    nop = 0,
    _,
};

pub const Nop = extern struct {
    pub const tag: Tag = .nop;
    pub const version: Version = 0;
};

pub fn Message(comptime Op: type) type {
    return extern struct {
        header: rmnet.ClientHeader,
        operation: Operation,

        pub const Operation = Op;

        pub fn init(userdata: u32, operation: Operation) @This() {
            return .{
                .header = .{
                    .protocol_version = .current,
                    .operation_version = Operation.version,
                    .operation_tag = Operation.tag,
                    .userdata = userdata,
                },
                .operation = operation,
            };
        }
    };
}

const rmnet = @import("root.zig");
