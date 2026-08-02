game_mode: ?GameMode,
player_accessory: ?PlayerAccessory,
main_city_time: ?MainCityTime,
pos_in_main_city: ?PosInMainCity,
npc_interaction: ?NpcInteraction,
control_avatar: ?ControlAvatar,
control_guise_avatar: ?ControlGuiseAvatar,
avatars: []const Avatar,
quick_teams: []const QuickTeam,
weapons: []const Weapon,
equipment: []const Equip,
hadal_zone: ?HadalZoneSchedule,

pub const init: Changes = .{
    .game_mode = null,
    .player_accessory = null,
    .main_city_time = null,
    .pos_in_main_city = null,
    .npc_interaction = null,
    .control_avatar = null,
    .control_guise_avatar = null,
    .avatars = &.{},
    .quick_teams = &.{},
    .weapons = &.{},
    .equipment = &.{},
    .hadal_zone = null,
};

/// Game mode switch.
pub const GameMode = union(enum) {
    hall: Hall,
    training: Training,
    hadal_zone: HadalZone,

    /// Load hall game mode.
    pub const Hall = struct {
        section_id: templates.section_config.Id,
        position: Properties.Hall.Position,
    };

    /// Load training game mode.
    pub const Training = struct {
        quest: templates.training_quest.Id,
        avatars: AvatarSlot.List,
    };

    /// Load hadal zone game mode.
    pub const HadalZone = struct {
        pub const Rooms = struct {
            pub const count = 2;

            pub const empty: Rooms = .{
                .avatar_lists = @splat(@splat(.none)),
                .buddies = @splat(.none),
            };

            avatar_lists: [count]AvatarSlot.List,
            buddies: [count]OptionalBuddy,
        };

        pub const Layer = struct {
            zone_id: ZoneId,
            room_index: u32,
            layer_index: u32,

            pub fn getId(layer: *const Layer) u32 {
                return switch (Group.fromZoneId(layer.zone_id)) {
                    .scheduled => switch (layer.room_index) {
                        0 => ZoneId.scheduled.toInt() * 100 + layer.layer_index,
                        else => ZoneId.impact.toInt() * 100 + layer.layer_index * 10 + layer.room_index,
                    },
                    .boss_challenge => ZoneId.boss_challenge.toInt() * 100 + layer.layer_index,
                    .stable => @intFromEnum(layer.zone_id) * 100 + layer.layer_index,
                    .free_training => 6900404,
                };
            }
        };

        rooms: Rooms,
        layer: Layer,
        layer_item_id: u32,
        quest_id: u32,
        quest_type: u32,

        pub const ZoneId = enum(u32) {
            scheduled = 62001,
            alive_count = 61002,
            impact = 62010,
            boss_challenge = 69001,
            free_training = 89001,
            _,

            pub fn fromInt(int: u32) ?ZoneId {
                if (Group.fromZoneIdInt(int) == null)
                    return null;

                return @enumFromInt(int);
            }

            pub inline fn toInt(id: ZoneId) u32 {
                return @intFromEnum(id);
            }
        };

        const Group = enum(u32) {
            stable = 61,
            scheduled = 62,
            boss_challenge = 69,
            free_training = 89,

            pub fn fromZoneId(id: ZoneId) Group {
                return fromZoneIdInt(@intFromEnum(id)).?;
            }

            pub fn fromZoneIdInt(int: u32) ?Group {
                var group_num = int;
                while ((group_num / 100) > 0) group_num /= 10;

                return std.enums.fromInt(Group, group_num);
            }
        };

        // TODO: LocalPlayType enum
        pub fn getPlayType(hz: *const HadalZone) u32 {
            return switch (hz.layer.zone_id) {
                .alive_count => 222, // HADAL_ZONE_ALIVECOUNT
                else => |zone_id| switch (Group.fromZoneId(zone_id)) {
                    .boss_challenge, .free_training => 224, // HADAL_ZONE_BOSSCHALLENGE
                    .stable, .scheduled => switch (hz.layer.room_index) {
                        0 => 209, // HADAL_ZONE
                        else => 303, // HADAL_ZONE_IMPACT_BATTLE
                    },
                },
            };
        }

        pub fn getEnemyPropertyScale(hz: *const HadalZone) u32 {
            return switch (hz.getPlayType()) {
                224 => 33,
                303 => 61,
                else => 19,
            };
        }
    };

    pub const OptionalBuddy = enum(u32) {
        none = 0,
        _,

        pub inline fn fromId(id: templates.buddy_base.Id) OptionalBuddy {
            return @enumFromInt(@intFromEnum(id));
        }

        pub inline fn toId(optional: OptionalBuddy) ?templates.buddy_base.Id {
            return switch (optional) {
                .none => null,
                else => |id| @enumFromInt(@intFromEnum(id)),
            };
        }
    };

    pub const AvatarSlot = enum(u32) {
        pub const count = 3;
        pub const List = [count]AvatarSlot;

        none = 0,
        _,

        pub inline fn fromId(id: templates.avatar_base.Id) AvatarSlot {
            return @enumFromInt(@intFromEnum(id));
        }

        pub inline fn toId(slot: AvatarSlot) ?templates.avatar_base.Id {
            return switch (slot) {
                .none => null,
                else => |id| @enumFromInt(@intFromEnum(id)),
            };
        }
    };
};

pub const PlayerAccessory = struct {
    avatar: Properties.PlayerAccessory.Avatar,
    meta: Properties.PlayerAccessory.Meta,
};

pub const MainCityTime = struct {
    time_in_minutes: u11,
    day_of_week: Properties.MainCityTime.DayOfWeek,
};

pub const PosInMainCity = struct {
    new_position: Properties.Hall.Position,
};

pub const NpcInteraction = struct {
    interact_index: u32,
};

pub const ControlAvatar = Properties.HallAvatar;

pub const ControlGuiseAvatar = struct {
    guise: Properties.HallAvatar.Guise,
    guise_skin: Properties.HallAvatar.Guise.Skin,
};

/// Avatar modification.
pub const Avatar = struct {
    id: Properties.Avatar.Id,
    meta: Properties.Avatar.Meta,
    weapon_uid: Properties.Avatar.OptionalUID,
    equipment_uids: [Properties.Avatar.equipment_slots]Properties.Avatar.OptionalUID,
    awake_material_count: Properties.Avatar.Awakening.Material,
};

pub const QuickTeam = struct {
    slot: Properties.QuickTeam.Slot,
    meta: Properties.QuickTeam.Meta,
};

pub const Weapon = struct {
    // The following didn't work out because notifier also has to know UID:
    // id: union(enum) {
    //     new: Properties.Weapon.Id,
    //     existing: Properties.Weapon.Uid,
    // },
    //
    // So the responsibility for generating UID is on the one who's constructing `Changes`.
    // I start to hate this "architecture" more and more.
    uid: Properties.Weapon.Uid,
    id: Properties.Weapon.Id, // absolutely redundant in case it's changing existing one.
    level: Properties.Weapon.Level,
    star: Properties.Weapon.Star,
    refine: Properties.Weapon.Refine,
};

pub const Equip = struct {
    // Same problem as with `Weapon`.
    uid: Properties.Equipment.Uid,
    id: u32,
    level: Properties.Equipment.Level,
    star: Properties.Equipment.Star,
    properties: Properties.Equipment.Property.List,
};

pub const HadalZoneSchedule = struct {};

pub const subset_marker_name = "logic_changes_subset_marker";

pub fn Subset(comptime types: anytype) type {
    var field_types: [types.len + 1]type = undefined;
    var field_names: [types.len + 1][]const u8 = undefined;

    // Add a ZST field as a marker
    field_types[0] = void;
    field_names[0] = subset_marker_name;

    const changes_fields = @typeInfo(Changes).@"struct".fields;

    for (types, field_types[1..], field_names[1..]) |C, *field_type, *field_name| {
        search: for (changes_fields) |changes_field| {
            if (changes_field.type == ?C) {
                field_type.* = ?*const C;
                field_name.* = changes_field.name;
                break :search;
            } else if (changes_field.type == []const C) {
                field_type.* = changes_field.type;
                field_name.* = changes_field.name;
                break :search;
            }
        } else @compileError("Invalid change type: " ++ @typeName(C));
    }

    return @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
}

pub fn Builder(comptime types: anytype) type {
    return struct {
        const Pointers = pointers: {
            const changes_fields = @typeInfo(Changes).@"struct".fields;

            var field_types: [types.len]type = undefined;
            var field_names: [types.len][]const u8 = undefined;

            for (types, &field_types, &field_names) |C, *field_type, *field_name| {
                search: for (changes_fields) |changes_field| {
                    if (changes_field.type == ?C or changes_field.type == []const C) {
                        field_type.* = *changes_field.type;
                        field_name.* = changes_field.name;
                        break :search;
                    }
                } else @compileError("Invalid change type: " ++ @typeName(C));
            }

            break :pointers @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
        };

        allocator: std.mem.Allocator,
        pointers: Pointers,

        pub fn init(allocator: std.mem.Allocator, changes: *Changes) @This() {
            var pointers: Pointers = undefined;

            inline for (@typeInfo(Pointers).@"struct".fields) |field| {
                @field(pointers, field.name) = &@field(changes, field.name);
            }

            return .{ .allocator = allocator, .pointers = pointers };
        }

        pub inline fn insert(builder: *const @This(), change: anytype) void {
            const Change = @TypeOf(change);

            switch (@typeInfo(Change)) {
                .pointer => |pointer| {
                    inline for (@typeInfo(Changes).@"struct".fields) |field| {
                        if (field.type == []const pointer.child) {
                            const ptr = @field(builder.pointers, field.name);
                            std.debug.assert(ptr.*.len == 0);
                            ptr.* = change;
                            break;
                        }
                    } else @compileError("invalid change type: " ++ @typeName(Change));
                },
                else => {
                    inline for (@typeInfo(Changes).@"struct".fields) |field| {
                        if (field.type == ?Change) {
                            const ptr = @field(builder.pointers, field.name);
                            std.debug.assert(ptr.* == null);
                            ptr.* = change;
                            break;
                        }
                    } else @compileError("invalid change type: " ++ @typeName(Change));
                },
            }
        }
    };
}

/// Returns `null` if not a single field is active.
pub fn extract(logic_changes: *const Changes, comptime Sub: type) ?Sub {
    var subset: Sub = undefined;
    var any_fulfilled: u1 = 0;

    inline for (@typeInfo(Sub).@"struct".fields) |field| {
        if (field.type == void) continue;

        switch (@typeInfo(field.type)) {
            .pointer => {
                @field(subset, field.name) = @field(logic_changes, field.name);
                any_fulfilled |= @intFromBool(@field(logic_changes, field.name).len != 0);
            },
            .optional => {
                @field(subset, field.name) = if (@field(logic_changes, field.name)) |*change|
                    change
                else
                    null;
                any_fulfilled |= @intFromBool(@field(logic_changes, field.name) != null);
            },
            else => comptime unreachable,
        }
    }

    return if (any_fulfilled != 0) subset else null;
}

const templates = Assets.templates;

const Assets = @import("../Assets.zig");
const Server = @import("../Server.zig");
const Properties = @import("Properties.zig");

const std = @import("std");
const Changes = @This();
