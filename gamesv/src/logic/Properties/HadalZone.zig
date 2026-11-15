pub const max_room_count = 2;
pub const max_avatar_per_room_count = 3;
pub const max_buddy_per_room_count = 1;
pub const max_battle_record_members_count = max_avatar_per_room_count + max_buddy_per_room_count;

zone_id: u32,
layer_index: u32,
sub_layer_index: u32,
layer_item_id: u32,
avatar_id_list: [max_room_count * max_avatar_per_room_count]u32,
buddy_id_list: [max_room_count * max_buddy_per_room_count]u32,
current_room_index: u32,
battle_records: [max_room_count]BattleRecordRoom,

pub const init: HadalZone = .{
    .zone_id = 0,
    .layer_index = 0,
    .sub_layer_index = 0,
    .layer_item_id = 0,
    .avatar_id_list = @splat(0),
    .buddy_id_list = @splat(0),
    .current_room_index = 0,
    .battle_records = @splat(.init),
};

pub const BattleRecordMember = struct {
    type: BattleRecordMemberType,
    id: u32,
    damage: u32,
    stun: u32,
    element_abnormal_accumulation: u32,
    recover: u32,
    shield: u32,

    pub const BattleRecordMemberType = enum(u2) {
        None = 0,
        Avatar = 1,
        Buddy = 2,
    };

    pub const init: BattleRecordMember = .{
        .type = .None,
        .id = 0,
        .damage = 0,
        .stun = 0,
        .element_abnormal_accumulation = 0,
        .recover = 0,
        .shield = 0,
    };

    pub fn fromBattleRecordMemberData(maybe_battle_record_member_data: ?pb.BattleRecordMemberData) BattleRecordMember {
        const battle_record_member_data = maybe_battle_record_member_data orelse return .init;

        return .{
            .type = if (battle_record_member_data.avatar_id != 0) .Avatar else .Buddy,
            .id = if (battle_record_member_data.avatar_id != 0) battle_record_member_data.avatar_id else battle_record_member_data.buddy_id,
            .damage = battle_record_member_data.damage,
            .stun = battle_record_member_data.stun,
            .element_abnormal_accumulation = battle_record_member_data.element_abnormal_accumulation,
            .recover = battle_record_member_data.recover,
            .shield = battle_record_member_data.shield,
        };
    }
};

pub const BattleRecordRoom = struct {
    room_id: u32,
    members: [max_battle_record_members_count]BattleRecordMember,

    pub const init: BattleRecordRoom = .{
        .room_id = 0,
        .members = @splat(.init),
    };
};

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const rmmem = @import("rmmem");
const pb = @import("rmpb").main;

const HadalZone = @This();
