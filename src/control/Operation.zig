const std = @import("std");
const alignForward = std.mem.alignForward;

const remielle = @import("../remielle.zig");
const ClientHeader = remielle.control.ClientHeader;

pub const Version = u8;

pub const Tag = enum(u16) {
    nop = 0,
    player_kick = 1,
    mod_avatar_meta = 2,
    create_weapon = 3,
    create_equip = 4,
    mod_hadal_zone_schedule = 5,
    _,
};

pub const Nop = extern struct {
    pub const tag: Tag = .nop;
    pub const version: Version = 0;
};

pub const PlayerKick = extern struct {
    pub const tag: Tag = .player_kick;
    pub const version: Version = 0;

    uid: u32,
    reason: i32,
};

pub const ModAvatarMeta = extern struct {
    pub const tag: Tag = .mod_avatar_meta;
    pub const version: Version = 0;

    pub const Field = enum(u8) {
        level = 0,
        exp = 1,
        rank = 2,
        talents = 3,
        mindscape_tab_state = 4,
        skill_level = 5,
        skin = 6,
        awakening = 7,
        favorite = 8,
        show_weapon = 9,
        _,
    };

    pub const Skill = packed struct(u64) {
        skill: u32,
        level: u32,
    };

    value: u64,
    player_uid: u32,
    avatar_id: u32,
    field: Field,
};

/// Trailing:
/// * `entries: [count]CreateWeapon.Entry`
pub const CreateWeapon = extern struct {
    pub const tag: Tag = .create_weapon;
    pub const version: Version = 0;

    player_uid: u32,
    count: u32,

    pub const Entry = extern struct {
        id: u16,
        meta: Meta,

        pub const Meta = packed struct(u16) {
            level: u6,
            star: u3,
            refine: u3,
            reserved: u4, // reserved.
        };
    };

    pub const trailing = struct {
        pub const entries_count_field = "count";
        pub const Entry = CreateWeapon.Entry;
    };
};

pub const CreateEquip = extern struct {
    pub const tag: Tag = .create_equip;
    pub const version: Version = 0;

    player_uid: u32,
    count: u32,

    pub const Entry = extern struct {
        properties: [5]Property,
        id: u16,
        meta: Meta,

        pub const Meta = packed struct(u16) {
            level: u4,
            star: u3,
            reserved: u9, // reserved.
        };

        pub const Property = packed struct(u32) {
            key: u16,
            base_value: u12,
            add_value: u4,
        };
    };

    pub const trailing = struct {
        pub const entries_count_field = "count";
        pub const Entry = CreateEquip.Entry;
    };
};

pub const ModHadalZoneSchedule = extern struct {
    pub const tag: Tag = .mod_hadal_zone_schedule;
    pub const version: Version = 0;

    count: u32,

    pub const Entry = extern struct {
        entrance_id: u32,
        zone_id: u32,
    };

    pub const trailing = struct {
        pub const entries_count_field = "count";
        pub const Entry = ModHadalZoneSchedule.Entry;
    };
};

pub fn Message(comptime Op: type) type {
    return extern struct {
        header: ClientHeader,
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

/// Used for constructing `Operation`s with dynamically-sized trailing data.
pub fn ExtendedMessageBuffer(comptime Op: type, comptime buffer_size: usize) type {
    return extern struct {
        base: Base,
        entries: [buffer_size]Op.trailing.Entry,

        pub const Base = Message(Op);

        pub fn init(base: Base) @This() {
            return .{
                .base = base,
                .entries = @splat(std.mem.zeroes(Op.trailing.Entry)),
            };
        }

        pub inline fn countPtr(buffer: *@This()) *u32 {
            return &@field(buffer.base.operation, Op.trailing.entries_count_field);
        }

        pub fn appendAssumeCapacity(buffer: *@This(), entry: Op.trailing.Entry) void {
            const count = buffer.countPtr();

            buffer.entries[count.*] = entry;
            count.* += 1;
        }

        pub fn payload(buffer: *const @This()) []const u8 {
            const entries_count = @field(buffer.base.operation, Op.trailing.entries_count_field);
            const entries_end = (&buffer.entries).ptr + entries_count;
            const len = @intFromPtr(entries_end) - @intFromPtr(buffer);
            return @as([*]const u8, @ptrCast(buffer))[0..len];
        }
    };
}
