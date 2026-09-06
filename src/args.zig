//! Command line argument parsing.

const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const assert = std.debug.assert;

/// `null` indicates that the parsing has failed,
/// in which case, the application must print the "usage" message
/// and exit.
///
/// When `-h` or `--help` is passed in `slice[1]`, the rest of slice is unchecked
/// and `null` is returned.
pub fn parse(
    /// The resulting structure to parse arguments as.
    /// Each field must have a default value.
    comptime Args: type,
    /// `std.log` or a result of `std.log.scoped`.
    /// Used to print out parse errors.
    comptime log: type,
    /// Result of `std.process.Args.toSlice`.
    slice: []const []const u8,
) ?Args {
    assert(slice.len != 0); // `slice` must include argv0.

    if (slice.len >= 2) {
        const argv1 = slice[1];
        if (mem.eql(u8, argv1, "-h") or mem.eql(u8, argv1, "--help"))
            return null;
    }

    const Enum = meta.FieldEnum(Args);
    const arg_types = @typeInfo(Args).@"struct".field_types;

    var result: Args = undefined;
    var seen_fields: [arg_types.len]bool = @splat(false);

    for (slice[1..]) |argument| {
        const key_string, const value_string = mem.cutScalar(u8, argument, '=') orelse .{ argument, "" };
        const key = meta.stringToEnum(Enum, key_string) orelse {
            log.err("unrecognized argument: {q}", .{key_string});
            return null;
        };

        switch (key) {
            inline else => |key_comptime| {
                const field_index = @backingInt(key_comptime);
                defer assert(seen_fields[field_index]);

                if (seen_fields[field_index]) {
                    log.err("duplicated argument: {q}", .{key_string});
                    return null;
                }

                seen_fields[field_index] = true;

                switch (arg_types[field_index]) {
                    []const u8 => @field(result, @tagName(key_comptime)) = value_string,
                    else => |ArgType| switch (@typeInfo(ArgType)) {
                        .int => {
                            const value_int = std.fmt.parseInt(ArgType, value_string, 0) catch {
                                log.err("invalid integer value for {q}", .{key_string});
                                return null;
                            };

                            @field(result, @tagName(key_comptime)) = value_int;
                        },
                        .@"enum" => {
                            const value_enum = meta.stringToEnum(ArgType, value_string) orelse {
                                log.err("invalid string value for {q}", .{key_string});
                                return null;
                            };

                            @field(result, @tagName(key_comptime)) = value_enum;
                        },
                        else => @compileError("unsupported argument type: " ++ @typeName(ArgType)),
                    },
                }
            },
        }
    }

    const arg_names = @typeInfo(Args).@"struct".field_names;
    const arg_attrs = @typeInfo(Args).@"struct".field_attrs;

    inline for (seen_fields, arg_types, arg_names, arg_attrs) |arg_seen, ArgType, arg_name, arg_attr| {
        comptime assert(arg_attr.default_value_ptr != null); // all arguments must have defaults.

        if (!arg_seen)
            @field(result, arg_name) = arg_attr.defaultValue(ArgType).?;
    }

    return result;
}

// Use this for tests that are expected to fail and the failure
// results in printing to stderr.
//
// For the tests that are not expected to print anything, pass `std.log`.
const testing_log_stub = struct {
    fn err(comptime _: []const u8, _: anytype) void {}
};

test "pass nothing" {
    const Args = struct {
        @"--string": []const u8 = "default_string",
    };

    const argv0_only = &.{"./application"};
    const expected: Args = .{};
    const parsed = parse(Args, std.log, argv0_only);
    try testing.expectEqualDeep(expected, parsed);
}

test "pass help" {
    const Args = struct {};

    const help_long = &.{
        "./application",
        "--help",
    };

    try testing.expectEqual(null, parse(Args, std.log, help_long));

    const help_short = &.{
        "./application",
        "--help",
    };

    try testing.expectEqual(null, parse(Args, std.log, help_short));
}

test "parse structure" {
    const Args = struct {
        @"--string": []const u8 = "",
        @"--int": u32 = 0,
        @"--signed-int": i32 = 0,
        @"--variant": enum {
            @"variant-a",
            @"variant-b",
        } = .@"variant-a",
    };

    const expected: Args = .{
        .@"--string" = "string_value",
        .@"--int" = 1024,
        .@"--signed-int" = -1,
        .@"--variant" = .@"variant-b",
    };

    var arena_instance: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = &.{
        "./application", // argv0
        try arena.print("--string={s}", .{expected.@"--string"}),
        try arena.print("--int=0x{X}", .{expected.@"--int"}),
        try arena.print("--signed-int={d}", .{expected.@"--signed-int"}),
        try arena.print("--variant={t}", .{expected.@"--variant"}),
    };

    const parsed = parse(Args, std.log, args);
    try testing.expectEqualDeep(expected, parsed);
}

test "unrecognized argument" {
    const Args = struct {};

    const args = &.{
        "./application", // argv0
        "--string=random",
    };

    try testing.expectEqual(null, parse(Args, testing_log_stub, args));
}

test "invalid value" {
    const Args = struct {
        int: i32 = 0,
    };

    const args = &.{
        "./application", // argv0
        "--int=definitely-an-integer",
    };

    try testing.expectEqual(null, parse(Args, testing_log_stub, args));
}
