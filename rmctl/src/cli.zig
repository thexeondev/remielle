pub const Command = union(enum) {
    pub const Tag = @typeInfo(Command).@"union".tag_type.?;

    @"kick-player": struct {
        uid: u32,
        reason: u31 = 3,
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

const std = @import("std");
