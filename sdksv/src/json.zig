pub const Escaping = enum {
    none,
    escaped_once,
};

/// Slices the requested fields from `string` as if it was in JSON format.
/// This function ignores any object nesting whatsoever.
pub fn view(comptime Struct: type, comptime escaping: Escaping, string: []const u8) ?Struct {
    var result: Struct = undefined;

    const quote = switch (escaping) {
        .none => "\"",
        .escaped_once => "\\\"",
    };

    inline for (@typeInfo(Struct).@"struct".field_names) |field_name| {
        const field_pattern = quote ++ field_name ++ quote ++ ":";
        const before_value_index = (std.mem.find(u8, string, field_pattern) orelse
            return null) + field_pattern.len;

        const before_value = string[before_value_index..];

        const value_start_index = switch (escaping) {
            .none => 1 + (std.mem.findScalar(u8, before_value, '"') orelse
                return null),
            .escaped_once => quote.len + (std.mem.find(u8, before_value, quote) orelse
                return null),
        };

        const value_unterminated = before_value[value_start_index..];

        if (value_unterminated.len == 0) return null;

        const value_termination = switch (escaping) {
            .none => std.mem.findScalar(u8, value_unterminated, '"') orelse
                return null,
            .escaped_once => std.mem.find(u8, value_unterminated, quote) orelse
                return null,
        };

        @field(result, field_name) = value_unterminated[0..value_termination];
    }

    return result;
}

const std = @import("std");
