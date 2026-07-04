pub const Version = u8;

pub const Tag = enum(u16) {
    nop = 0,
    player_kick = 1,
    mod_avatar_meta = 2,
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
