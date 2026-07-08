pub const Command = union(enum) {
    pub const Tag = @typeInfo(Command).@"union".tag_type.?;

    @"kick-player": struct {
        uid: u32,
        reason: u31 = 3,
    },
    @"mod-avatar-meta": struct {
        field: rmnet.Operation.ModAvatarMeta.Field,
        uid: u32,
        id: u32,
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
                var params: Struct = undefined;
                var cursor = args[1..];

                inline for (@typeInfo(Struct).@"struct".fields) |field| {
                    if (cursor.len == 0) {
                        if (field.defaultValue()) |default_value|
                            @field(params, field.name) = default_value
                        else
                            fatal("not enough provided arguments for command " ++ @tagName(tag), .{});
                    } else {
                        const string = cursor[0];
                        cursor = cursor[1..];

                        switch (@typeInfo(field.type)) {
                            .int => {
                                const int = std.fmt.parseInt(field.type, string, 10) catch
                                    fatal("invalid value for " ++ field.name, .{});

                                @field(params, field.name) = int;
                            },
                            .@"enum" => {
                                const e = std.meta.stringToEnum(field.type, string) orelse
                                    fatal("invalid value for " ++ field.name, .{});

                                @field(params, field.name) = e;
                            },
                            else => @compileError("unsupported argument type: " ++ @typeName(field.type)),
                        }
                    }
                }

                return @unionInit(Command, @tagName(tag), params);
            },
        }
    }
};

const fatal = std.process.fatal;

const rmnet = @import("rmnet");
const std = @import("std");
