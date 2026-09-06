pub const Control = @import("kcp/Control.zig");
pub const Header = @import("kcp/Header.zig");
pub const MultiConversation = @import("kcp/MultiConversation.zig");

pub const mtu: usize = 1200;
pub const mss: usize = mtu - Header.size;

pub const ConvId = enum(u32) {
    none = 0,
    _,

    pub const Counter = struct {
        count: u32,

        pub const init: Counter = .{ .count = 1 };

        pub fn next(c: *Counter) ConvId {
            defer c.count +%= 1;

            if (c.count == 0) {
                @branchHint(.cold);
                c.count +%= 1;
            }

            return @fromBackingInt(@intCast(c.count));
        }
    };

    pub fn toInt(conv: ConvId) u32 {
        std.debug.assert(conv != .none);
        return @backingInt(conv);
    }
};

pub const Token = enum(u32) {
    _,

    const Parameters = packed struct {
        random: u64,
        conv_id: ConvId,
        addr: u32,
    };

    pub fn init(parameters: *const Parameters) Token {
        return @fromBackingInt(@intCast(std.hash.Crc32.hash(@as([]const u8, @ptrCast(parameters))[0..16])));
    }

    pub inline fn downgrade(token: Token) Unchecked {
        return @fromBackingInt(@intCast(@backingInt(token)));
    }

    /// An unchecked, just-received-from-the-wire token value.
    pub const Unchecked = enum(u32) {
        _,

        pub fn upgrade(unchecked: Unchecked, random: u64, user_addr: u32, user_conv: ConvId) ?Token {
            const actual: Token = .init(&.{
                .random = random,
                .conv_id = user_conv,
                .addr = user_addr,
            });

            return if (@backingInt(actual) == @backingInt(unchecked))
                actual
            else
                null;
        }
    };
};

pub const Timeval = packed struct {
    milliseconds: u32,

    pub const zero: Timeval = .{ .milliseconds = 0 };

    pub fn fromTimestamp(t: Io.Timestamp) Timeval {
        return .{ .milliseconds = @truncate(@as(u64, @bitCast(t.toMilliseconds()))) };
    }
};

const Io = std.Io;

const rmio = @import("rmio");
const std = @import("std");
