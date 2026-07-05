const std = @import("std");
fn MapEntry(comptime K: type, comptime V: type) type {
    return struct {
        pub const map_entry: void = {};
        pub const init: @This() = .{
            .key = switch (@typeInfo(K)) {
                .int => 0,
                .bool => false,
                else => if (K == []const u8) "" else .init,
            },
            .value = switch (@typeInfo(V)) {
                .int => 0,
                .bool => false,
                else => if (V == []const u8) "" else .init,
            },
        };

        pub const key_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
        pub const value_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };

        key: K,
        value: V,
    };
}

pub const FieldDesc = struct {
    number: u32,
    xor: u32,
};
pub const PacketHead = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "PacketHead";
    packet_id: u32 = 0,
    ack_packet_id: u32 = 0,
    pub const packet_id_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const ack_packet_id_field_desc: FieldDesc = .{ .number = 11, .xor = 0 };
};

pub const ActionOpenUi = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "ActionOpenUi";
    ui: []const u8 = "",
    args: i32 = 0,
    store_template_id: u32 = 0,
    npc_id: u32 = 0,
    pub const ui_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const args_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const store_template_id_field_desc: FieldDesc = .{ .number = 4, .xor = 0 };
    pub const npc_id_field_desc: FieldDesc = .{ .number = 5, .xor = 0 };
};

pub const ActionSwitchSection = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "ActionSwitchSection";
    section_id: u32 = 0,
    transform_id: []const u8 = "",
    camera_x: u32 = 0,
    camera_y: u32 = 0,
    pub const section_id_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const transform_id_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const camera_x_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
    pub const camera_y_field_desc: FieldDesc = .{ .number = 4, .xor = 0 };
};

pub const PlayerSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "PlayerSave";
    basic: ?BasicSave = null,
    avatar: ?AvatarSave = null,
    weapon: ?WeaponSave = null,
    equip: ?EquipSave = null,
    buddy: ?BuddySave = null,
    hall: ?HallSave = null,
    main_city_time: ?MainCityTimeSave = null,
    quick_team: ?QuickTeamSave = null,
    player_accessory: ?PlayerAccessorySave = null,
    pub const basic_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const avatar_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const weapon_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
    pub const equip_field_desc: FieldDesc = .{ .number = 4, .xor = 0 };
    pub const buddy_field_desc: FieldDesc = .{ .number = 5, .xor = 0 };
    pub const hall_field_desc: FieldDesc = .{ .number = 6, .xor = 0 };
    pub const main_city_time_field_desc: FieldDesc = .{ .number = 8, .xor = 0 };
    pub const quick_team_field_desc: FieldDesc = .{ .number = 9, .xor = 0 };
    pub const player_accessory_field_desc: FieldDesc = .{ .number = 10, .xor = 0 };
};

pub const BasicSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "BasicSave";
    level: u32 = 0,
    avatar_id: u32 = 0,
    control_avatar_id: u32 = 0,
    control_guise_avatar_id: u32 = 0,
    control_guise_avatar_skin_id: u32 = 0,
    pub const level_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const avatar_id_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const control_avatar_id_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
    pub const control_guise_avatar_id_field_desc: FieldDesc = .{ .number = 4, .xor = 0 };
    pub const control_guise_avatar_skin_id_field_desc: FieldDesc = .{ .number = 5, .xor = 0 };
};

pub const AvatarSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "AvatarSave";
    items: std.ArrayList(AvatarItemSave) = .empty,
    pub const items_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
};

pub const AvatarItemSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "AvatarItemSave";
    id: u32 = 0,
    level: u32 = 0,
    exp: u32 = 0,
    rank: u32 = 0,
    talents: u32 = 0,
    mindscape_tab_state: u32 = 0,
    favorite: bool = false,
    skill_levels: std.ArrayList(u32) = .empty,
    skin_id: u32 = 0,
    awake_available: bool = false,
    awake_enabled: bool = false,
    awake_id: u32 = 0,
    show_weapon: u32 = 0,
    weapon_uid: u32 = 0,
    equipment_uids: std.ArrayList(u32) = .empty,
    awake_material_count: u32 = 0,
    pub const id_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const level_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const exp_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
    pub const rank_field_desc: FieldDesc = .{ .number = 4, .xor = 0 };
    pub const talents_field_desc: FieldDesc = .{ .number = 5, .xor = 0 };
    pub const mindscape_tab_state_field_desc: FieldDesc = .{ .number = 6, .xor = 0 };
    pub const favorite_field_desc: FieldDesc = .{ .number = 7, .xor = 0 };
    pub const skill_levels_field_desc: FieldDesc = .{ .number = 8, .xor = 0 };
    pub const skin_id_field_desc: FieldDesc = .{ .number = 9, .xor = 0 };
    pub const awake_available_field_desc: FieldDesc = .{ .number = 12, .xor = 0 };
    pub const awake_enabled_field_desc: FieldDesc = .{ .number = 13, .xor = 0 };
    pub const awake_id_field_desc: FieldDesc = .{ .number = 14, .xor = 0 };
    pub const show_weapon_field_desc: FieldDesc = .{ .number = 16, .xor = 0 };
    pub const weapon_uid_field_desc: FieldDesc = .{ .number = 10, .xor = 0 };
    pub const equipment_uids_field_desc: FieldDesc = .{ .number = 11, .xor = 0 };
    pub const awake_material_count_field_desc: FieldDesc = .{ .number = 15, .xor = 0 };
};

pub const WeaponSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "WeaponSave";
    items: std.ArrayList(WeaponItemSave) = .empty,
    pub const items_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
};

pub const WeaponItemSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "WeaponItemSave";
    uid: u32 = 0,
    id: u32 = 0,
    level: u32 = 0,
    star: u32 = 0,
    refine: u32 = 0,
    pub const uid_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const id_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const level_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
    pub const star_field_desc: FieldDesc = .{ .number = 4, .xor = 0 };
    pub const refine_field_desc: FieldDesc = .{ .number = 5, .xor = 0 };
};

pub const EquipSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "EquipSave";
    items: std.ArrayList(EquipItemSave) = .empty,
    pub const items_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
};

pub const EquipItemSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "EquipItemSave";
    uid: u32 = 0,
    id: u32 = 0,
    level: u32 = 0,
    star: u32 = 0,
    properties: std.ArrayList(EquipProperty) = .empty,
    pub const uid_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const id_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const level_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
    pub const star_field_desc: FieldDesc = .{ .number = 4, .xor = 0 };
    pub const properties_field_desc: FieldDesc = .{ .number = 5, .xor = 0 };
};

pub const EquipProperty = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "EquipProperty";
    key: u32 = 0,
    base_value: u32 = 0,
    add_value: u32 = 0,
    pub const key_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const base_value_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const add_value_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
};

pub const BuddySave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "BuddySave";
    items: std.ArrayList(BuddyItemSave) = .empty,
    pub const items_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
};

pub const BuddyItemSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "BuddyItemSave";
    id: u32 = 0,
    level: u32 = 0,
    exp: u32 = 0,
    rank: u32 = 0,
    star: u32 = 0,
    favorite: bool = false,
    skill_levels: std.ArrayList(u32) = .empty,
    pub const id_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const level_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const exp_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
    pub const rank_field_desc: FieldDesc = .{ .number = 4, .xor = 0 };
    pub const star_field_desc: FieldDesc = .{ .number = 5, .xor = 0 };
    pub const favorite_field_desc: FieldDesc = .{ .number = 6, .xor = 0 };
    pub const skill_levels_field_desc: FieldDesc = .{ .number = 7, .xor = 0 };
};

pub const HallSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "HallSave";
    section_id: u32 = 0,
    position_id: []const u8 = "",
    position_transform: ?Transform = null,
    pub const section_id_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const position_id_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const position_transform_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
};

pub const Transform = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "Transform";
    position: std.ArrayList(f64) = .empty,
    rotation: std.ArrayList(f64) = .empty,
    pub const position_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const rotation_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
};

pub const MainCityTimeSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "MainCityTimeSave";
    time_in_minutes: u32 = 0,
    day_of_week: u32 = 0,
    pub const time_in_minutes_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const day_of_week_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
};

pub const PlayerAccessorySave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "PlayerAccessorySave";
    avatars: std.ArrayList(PlayerAccessoryItemSave) = .empty,
    pub const avatars_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
};

pub const PlayerAccessoryItemSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "PlayerAccessoryItemSave";
    id: u32 = 0,
    skin_id: u32 = 0,
    pub const id_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const skin_id_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
};

pub const QuickTeamSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "QuickTeamSave";
    teams: std.ArrayList(QuickTeamItemSave) = .empty,
    pub const teams_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
};

pub const QuickTeamItemSave = struct {
    pub const init: @This() = .{};
    pub const pb_desc_name = "QuickTeamItemSave";
    name: []const u8 = "",
    avatar_ids: std.ArrayList(u32) = .empty,
    buddy_id: u32 = 0,
    pub const name_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
    pub const avatar_ids_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
    pub const buddy_id_field_desc: FieldDesc = .{ .number = 3, .xor = 0 };
};

