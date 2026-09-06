const std = @import("std");
const fatal = std.process.fatal;

const remielle = @import("remielle");
const templates = remielle.assets.templates;

pub const Command = union(enum) {
    pub const Tag = @typeInfo(Command).@"union".tag_type.?;

    @"kick-player": struct {
        uid: u32,
        reason: u31 = 3,
    },
    @"mod-avatar-meta": struct {
        field: remielle.control.Operation.ModAvatarMeta.Field,
        uid: u32,
        id: templates.avatar_base.Id,
        value: u32,
        value_extra: u32 = 0,
    },
    @"create-weapon": struct {
        player_uid: u32,
        item_id: u16,
        level: u6,
        star: u3,
        refine: u3,
    },
    @"create-equip": struct {
        player_uid: u32,
        item_id: u16,
        level: u4,
        star: u3,

        // TODO: should we support arrays here?
        property_key_0: u16,
        property_base_value_0: u12,
        property_add_value_0: u4,

        property_key_1: u16 = 0,
        property_base_value_1: u12 = 0,
        property_add_value_1: u4 = 0,

        property_key_2: u16 = 0,
        property_base_value_2: u12 = 0,
        property_add_value_2: u4 = 0,

        property_key_3: u16 = 0,
        property_base_value_3: u12 = 0,
        property_add_value_3: u4 = 0,

        property_key_4: u16 = 0,
        property_base_value_4: u12 = 0,
        property_add_value_4: u4 = 0,
    },
    @"random-equip": struct {
        player_uid: u32,
        amount: u12,
    },
    @"mod-hadal-entrance": struct {
        entrance: enum(u32) {
            free_training = 0,
            hadal_zone_scheduled_1 = 1,
            hadal_zone_stable = 2,
            hadal_zone_defensive = 3,
            hadal_zone_ambush = 4,
            boss_challenge_trial_1 = 9,
            boss_challenge_trial_2 = 10,
            boss_challenge_trial_3 = 11,
            // 12 is an empty spacer
            hadal_zone_scheduled_2 = 13,
            hadal_zone_scheduled_3 = 14,
            // 15 is an empty spacer
            boss_challenge_adversity_1 = 16,
            boss_challenge_adversity_2 = 17,
            boss_challenge_adversity_3 = 18,
            boss_challenge_adversity_4 = 19,
        },
        zone_id: u32,
    },

    /// Exits on invalid input.
    pub fn parse(
        /// Should *not* include argv[0]
        args: []const []const u8,
    ) Command {
        if (args.len == 0)
            fatal("usage: rmctl [action] [arguments]", .{});

        const user_tag = std.meta.stringToEnum(Command.Tag, args[0]) orelse
            fatal("invalid action provided; consider reading the source to find out what's accepted.", .{});

        switch (user_tag) {
            inline else => |tag| {
                const Struct = @FieldType(Command, @tagName(tag));
                const struct_info = @typeInfo(Struct).@"struct";

                var params: Struct = undefined;
                var cursor = args[1..];

                inline for (
                    struct_info.field_types,
                    struct_info.field_names,
                    struct_info.field_attrs,
                ) |FieldType, field_name, field_attrs| {
                    if (cursor.len == 0) {
                        if (field_attrs.defaultValue(FieldType)) |default_value|
                            @field(params, field_name) = default_value
                        else
                            fatal("not enough provided arguments for command " ++ @tagName(tag), .{});
                    } else {
                        const string = cursor[0];
                        cursor = cursor[1..];

                        switch (@typeInfo(FieldType)) {
                            .int => {
                                const int = std.fmt.parseInt(FieldType, string, 10) catch
                                    fatal("invalid value for " ++ field_name, .{});

                                @field(params, field_name) = int;
                            },
                            .@"enum" => |enum_info| {
                                const e = blk: {
                                    if (std.fmt.parseInt(
                                        enum_info.tag_type,
                                        string,
                                        10,
                                    )) |int| {
                                        break :blk std.enums.fromInt(FieldType, int);
                                    } else |_| {
                                        break :blk std.meta.stringToEnum(FieldType, string);
                                    }
                                } orelse fatal("invalid value for " ++ field_name, .{});

                                @field(params, field_name) = e;
                            },
                            else => @compileError("unsupported argument type: " ++ @typeName(FieldType)),
                        }
                    }
                }

                return @unionInit(Command, @tagName(tag), params);
            },
        }
    }
};
