const std = @import("std");
const Io = std.Io;

pub fn parseOptions(
    comptime Options: type,
    /// Must not include argv0
    args: []const []const u8,
    error_desc: *ErrorDescription,
) ?Options {
    const option_fields = @typeInfo(Options).@"struct".fields;
    const Option = comptime Option: {
        var field_names: [option_fields.len][:0]const u8 = undefined;
        var flags: [option_fields.len]u8 = undefined;

        for (option_fields, &flags, &field_names) |option_field, *flag, *name| {
            flag.* = option_field.name[0];
            name.* = option_field.name;
        }

        break :Option @Enum(u8, .exhaustive, &field_names, &flags);
    };

    var options: Options = .{};

    var opt_stack_buffer: [option_fields.len]Option = undefined;
    var opt_stack: std.ArrayList(Option) = .initBuffer(&opt_stack_buffer);

    for (args) |arg| if (arg[0] == '-') {
        for (arg[1..]) |char| if (std.enums.fromInt(Option, char)) |flag| {
            switch (flag) {
                inline else => |f| switch (@FieldType(Options, @tagName(f))) {
                    bool => @field(options, @tagName(f)) = true,
                    else => opt_stack.appendBounded(flag) catch |err| switch (err) {
                        error.OutOfMemory => {
                            error_desc.* = .too_much_options;
                            return null;
                        },
                    },
                },
            }
        } else {
            error_desc.* = .{ .invalid_option = char };
            return null;
        };
    } else {
        if (opt_stack.items.len == 0) {
            error_desc.* = .{ .redundant_argument = arg };
            return null;
        }

        switch (opt_stack.swapRemove(0)) {
            inline else => |flag| switch (@FieldType(Options, @tagName(flag))) {
                []const u8 => @field(options, @tagName(flag)) = arg,
                bool => {
                    error_desc.* = .{ .redundant_argument = arg };
                    return null;
                },
                else => |T| {
                    switch (@typeInfo(T)) {
                        .int => @field(options, @tagName(flag)) = std.fmt.parseInt(T, arg, 0) catch {
                            error_desc.* = .{ .invalid_value = @tagName(flag)[0] };
                            return null;
                        },
                        .@"enum" => @field(options, @tagName(flag)) = std.meta.stringToEnum(T, arg) catch {
                            error_desc.* = .{ .invalid_value = @tagName(flag)[0] };
                            return null;
                        },
                        else => @compileError("unsupported option type: " ++ @typeName(T)),
                    }
                },
            },
        }
    };

    if (opt_stack.items.len != 0) {
        error_desc.* = .{ .missing_argument = @intFromEnum(opt_stack.items[0]) };
        return null;
    }

    return options;
}

pub const ErrorDescription = union(enum) {
    invalid_option: u8,
    invalid_value: u8,
    too_much_options: void,
    redundant_argument: []const u8,
    missing_argument: u8,

    pub fn format(desc: ErrorDescription, writer: *Io.Writer) !void {
        return switch (desc) {
            .invalid_option => |char| writer.print("invalid option -- '{c}'", .{char}),
            .invalid_value => |char| writer.print("invalid value for option '{c}'", .{char}),
            .too_much_options => writer.writeAll("too much options encountered"),
            .redundant_argument => |str| writer.print("unexpected trailing argument -- '{s}'", .{str}),
            .missing_argument => |char| writer.print("option requires an argument -- '{c}'", .{char}),
        };
    }
};

pub fn Usage(comptime Args: type) type {
    return struct {
        const usage_string = blk: {
            const fields = @typeInfo(Args).@"struct".fields;
            var fmt: []const u8 = "";

            for (fields) |field| if (field.type == bool) {
                if (fmt.len == 0) fmt = "[-";
                fmt = fmt ++ .{field.name[0]};
            };

            if (fmt.len != 0) fmt = fmt ++ "]";

            for (fields) |field| if (field.type != bool) {
                if (fmt.len != 0) fmt = fmt ++ " ";
                fmt = fmt ++ "[-" ++ .{field.name[0]} ++ " " ++ field.name ++ "]";
            };

            break :blk fmt;
        };

        pub fn format(writer: *Io.Writer) !void {
            return writer.writeAll(usage_string);
        }
    };
}
