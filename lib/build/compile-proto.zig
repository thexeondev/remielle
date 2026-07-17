const std = @import("std");
const Io = std.Io;
const Init = std.process.Init;
const exit = std.process.exit;
const fatal = std.process.fatal;
const Allocator = std.mem.Allocator;

const CompilationMode = enum {
    full,
    structures,
    descriptors,

    pub fn outputStructures(cm: CompilationMode) bool {
        return switch (cm) {
            .full, .structures => true,
            .descriptors => false,
        };
    }

    pub fn outputDescriptors(cm: CompilationMode) bool {
        return switch (cm) {
            .full, .descriptors => true,
            .structures => false,
        };
    }
};

pub fn main(init: Init) noreturn {
    const io = init.io;
    const gpa = init.gpa;

    const cwd: Io.Dir = .cwd();

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err|
        fatal("failed to collect cli arguments: {t}", .{err});

    if (args.len <= 1) fatal("no input files", .{});

    var mode: CompilationMode = .full;
    var fw_buf: [4096]u8 = undefined;
    var fw = Io.File.writerStreaming(.stdout(), io, &fw_buf);

    writeOutputFileHeader(&fw.interface) catch
        fatal("write failed: {t}", .{fw.err.?});

    var file_arena: std.heap.ArenaAllocator = .init(gpa);
    defer file_arena.deinit();

    for (args[1..]) |arg| switch (arg[0]) {
        '-' => {
            mode = std.meta.stringToEnum(CompilationMode, arg[1..]) orelse
                fatal("invalid parameter specified: {s}", .{arg});
        },
        else => {
            defer _ = file_arena.reset(.retain_capacity);

            const content = cwd.readFileAlloc(io, arg, gpa, .unlimited) catch |err|
                fatal("couldn't read input file '{s}': {t}", .{ arg, err });

            defer gpa.free(content);

            if (content[content.len - 1] != '\n')
                fatal("input file '{s}' doesn't have a terminating newline", .{arg});

            writeGeneratedCodeForProto(file_arena.allocator(), &fw.interface, content, arg, mode) catch |err|
                fatal("failed to generate code for '{s}': {t}", .{ arg, err });
        },
    };

    fw.interface.flush() catch @panic("stdout flush");
    exit(0);
}

fn writeOutputFileHeader(out: *Io.Writer) Io.Writer.Error!void {
    try out.writeAll(
        \\const std = @import("std");
        \\fn MapEntry(comptime K: type, comptime V: type) type {
        \\    return struct {
        \\        pub const map_entry: void = {};
        \\        pub const init: @This() = .{
        \\            .key = switch (@typeInfo(K)) {
        \\                .int => 0,
        \\                .bool => false,
        \\                else => if (K == []const u8) "" else .init,
        \\            },
        \\            .value = switch (@typeInfo(V)) {
        \\                .int => 0,
        \\                .bool => false,
        \\                else => if (V == []const u8) "" else .init,
        \\            },
        \\        };
        \\
        \\        pub const key_field_desc: FieldDesc = .{ .number = 1, .xor = 0 };
        \\        pub const value_field_desc: FieldDesc = .{ .number = 2, .xor = 0 };
        \\
        \\        key: K,
        \\        value: V,
        \\    };
        \\}
        \\
        \\pub const FieldDesc = struct {
        \\    number: u32,
        \\    xor: u32,
        \\};
        \\
    );
}

fn writeGeneratedCodeForProto(
    arena: Allocator,
    out: *Io.Writer,
    input_proto: []const u8,
    input_path: []const u8,
    mode: CompilationMode,
) !void {
    var l: Lexer = .init(input_path, input_proto);

    while (!l.isAtEnd()) {
        const keyword = try l.expect(.keyword);
        switch (keyword.keyword) {
            .syntax => {
                try l.expectPunct(.equal_sign);
                const syntax = try l.expect(.quoted);
                if (!std.mem.eql(u8, syntax.quoted, "proto3")) {
                    std.log.err("{f}", .{Diagnostic.custom(&l, syntax, "unsupported syntax; this compiler only supports \"proto3\"")});
                    return error.UnsupportedSyntax;
                }
                try l.expectPunct(.semicolon);
            },
            .package => {
                while (true) {
                    _ = try l.expect(.name);
                    const p = try l.expect(.punct);
                    switch (p.punct) {
                        .semicolon => break,
                        .dot => continue,
                        else => {
                            std.log.err("{f}", .{Diagnostic.unexpected(&l, p)});
                            return error.UnexpectedToken;
                        },
                    }
                }
            },
            .option => {
                _ = try l.expect(.name);
                try l.expectPunct(.equal_sign);
                _ = try l.expect(.quoted);
                try l.expectPunct(.semicolon);
            },
            .import => {
                _ = try l.expect(.quoted);
                try l.expectPunct(.semicolon);
            },
            .@"enum" => try compileEnum(mode, &l, out),
            .message => try compileMessage(mode, arena, &l, out),
            else => {
                std.log.err("{f}", .{Diagnostic.unexpected(&l, keyword)});
                return error.UnexpectedToken;
            },
        }
    }
}

fn compileEnum(mode: CompilationMode, l: *Lexer, out: *Io.Writer) !void {
    const name = try l.expect(.name);
    const output_structures = mode.outputStructures();

    if (output_structures)
        try out.print("pub const {s} = enum(i32) {{\n", .{name.name});

    try l.expectPunct(.open_curly);

    while (true) {
        const token = try l.next() orelse return error.EndOfFile;
        if (std.meta.activeTag(token) == .punct and token.punct == .close_curly) break;

        if (std.meta.activeTag(token) != .name) {
            std.log.err("{f}", .{Diagnostic.unexpected(l, token)});
            return error.UnexpectedToken;
        }

        try l.expectPunct(.equal_sign);
        const discriminant = try l.expect(.number);
        try l.expectPunct(.semicolon);

        if (output_structures)
            try out.print("    {s} = {s},\n", .{ token.name, discriminant.number });
    }

    if (output_structures)
        try out.writeAll("};\n\n");
}

const FieldType = union(enum) {
    regular: []const u8,
    repeated: []const u8,
    map: struct {
        key: []const u8,
        value: []const u8,
    },

    pub fn parse(l: *Lexer, token: Lexer.Token) !FieldType {
        if (std.meta.activeTag(token) == .keyword and token.keyword == .repeated) {
            return .{ .repeated = (try l.expect(.name)).name };
        } else if (std.meta.activeTag(token) == .keyword and token.keyword == .map) {
            try l.expectPunct(.open_triangle);
            const key = (try l.expect(.name)).name;
            try l.expectPunct(.comma);
            const value = (try l.expect(.name)).name;
            try l.expectPunct(.close_triangle);

            return .{ .map = .{
                .key = key,
                .value = value,
            } };
        } else if (std.meta.activeTag(token) == .name) {
            return .{ .regular = token.name };
        } else {
            std.log.err("{f}", .{Diagnostic.unexpected(l, token)});
            return error.UnexpectedToken;
        }
    }

    pub fn format(ft: FieldType, w: *Io.Writer) !void {
        switch (ft) {
            .regular => |name| try w.print("{f}", .{TypeName{ .name = name, .standalone = true }}),
            .repeated => |name| try w.print("std.ArrayList({f})", .{TypeName{ .name = name }}),
            .map => |kv| try w.print("std.ArrayList(MapEntry({f}, {f}))", .{
                TypeName{ .name = kv.key },
                TypeName{ .name = kv.value },
            }),
        }
    }

    const TypeName = struct {
        name: []const u8,
        standalone: bool = false,

        pub fn format(tn: TypeName, w: *Io.Writer) !void {
            if (std.meta.stringToEnum(Primitive, tn.name)) |primitive| {
                try w.print("{f}", .{primitive});
            } else {
                if (tn.standalone) try w.writeByte('?');
                try w.print("{s}", .{tn.name});
            }
        }
    };

    const Primitive = enum {
        bool,
        int32,
        int64,
        uint32,
        uint64,
        string,
        bytes,
        float,
        double,

        pub fn format(p: Primitive, w: *Io.Writer) !void {
            try w.writeAll(switch (p) {
                .bool => "bool",
                .int32 => "i32",
                .int64 => "i64",
                .uint32 => "u32",
                .uint64 => "u64",
                .string, .bytes => "[]const u8",
                .float => "f32",
                .double => "f64",
            });
        }
    };
};

const FieldDesc = struct {
    name: []const u8,
    number: []const u8,
    xor: ?[]const u8,
};

fn compileMessage(mode: CompilationMode, arena: Allocator, l: *Lexer, out: *Io.Writer) !void {
    const name = try l.expect(.name);
    const output_structures = mode.outputStructures();
    const output_descriptors = mode.outputDescriptors();

    try out.print("pub const {s} = struct {{\n", .{name.name});
    if (output_structures) {
        try out.writeAll("    pub const init: @This() = .{};\n");
        try out.print("    pub const pb_desc_name = \"{s}\";\n", .{name.name});
    }

    try l.expectPunct(.open_curly);

    var cmd_id: ?[]const u8 = null;
    var field_descs: std.ArrayList(FieldDesc) = .empty;

    while (true) {
        const token = try l.next() orelse return error.EndOfFile;
        if (std.meta.activeTag(token) == .punct and token.punct == .close_curly) break;

        if (std.meta.activeTag(token) == .keyword and token.keyword == .oneof) {
            const oneof_name = try l.expect(.name);
            try l.expectPunct(.open_curly);

            if (output_structures)
                try out.print("    {s}: ?union(enum) {{\n", .{oneof_name.name});

            while (true) {
                const t = try l.next() orelse return error.EndOfFile;
                if (std.meta.activeTag(t) == .punct and t.punct == .close_curly) break;
                if (std.meta.activeTag(t) != .name) {
                    std.log.err("{f}", .{Diagnostic.unexpected(l, t)});
                    return error.UnexpectedToken;
                }

                const field_type = try FieldType.parse(l, t);
                const field_name = try l.expectNameOrKeyword();
                try l.expectPunct(.equal_sign);
                const field_number = (try l.expect(.number)).number;
                try l.expectPunct(.semicolon);

                if (output_structures)
                    try out.print("        {s}: {f},\n", .{ field_name, field_type });

                try field_descs.append(arena, .{
                    .name = field_name,
                    .number = field_number,
                    .xor = null,
                });
            }

            if (output_structures)
                try out.writeAll("    },\n");

            continue;
        } else if (std.meta.activeTag(token) == .keyword and token.keyword == .option) {
            try l.expectPunct(.open_paren);
            const option = (try l.expect(.name));

            if (!std.mem.eql(u8, option.name, "cmd_id")) {
                std.log.err("{f}", .{Diagnostic.custom(l, option, "unsupported message option; the only supported one: \"cmd_id\"")});
                return error.UnsupportedOption;
            }

            try l.expectPunct(.close_paren);
            try l.expectPunct(.equal_sign);
            cmd_id = (try l.expect(.number)).number;
            try l.expectPunct(.semicolon);
            continue;
        }

        const field_type = try FieldType.parse(l, token);
        const field_name = try l.expectNameOrKeyword();
        try l.expectPunct(.equal_sign);
        const field_number = (try l.expect(.number)).number;

        const xor: ?[]const u8 = switch (try l.expectPuncts(&.{ .semicolon, .open_square })) {
            .semicolon => null,
            .open_square => blk: {
                try l.expectPunct(.open_paren);
                const option = try l.expect(.name);

                if (!std.mem.eql(u8, option.name, "xor")) {
                    std.log.err("{f}", .{Diagnostic.custom(l, option, "unsupported field option; the only supported one: \"xor\"")});
                    return error.UnsupportedOption;
                }

                try l.expectPunct(.close_paren);
                try l.expectPunct(.equal_sign);
                const xor_val = (try l.expect(.number)).number;
                try l.expectPunct(.close_square);
                try l.expectPunct(.semicolon);

                break :blk xor_val;
            },
        };

        try field_descs.append(arena, .{
            .name = field_name,
            .number = field_number,
            .xor = xor,
        });

        if (output_structures)
            try out.print("    {s}: {f} = {s},\n", .{ field_name, field_type, switch (field_type) {
                .regular => |regular| if (std.meta.stringToEnum(FieldType.Primitive, regular)) |p| switch (p) {
                    .int32, .int64, .uint32, .uint64, .float, .double => "0",
                    .string, .bytes => "\"\"",
                    .bool => "false",
                } else "null",
                .repeated, .map => ".empty",
            } });
    }

    if (output_descriptors) {
        if (cmd_id) |id| {
            try out.print("    pub const cmd_id: u16 = {s};\n", .{id});
        }

        for (field_descs.items) |desc| {
            try out.print(
                "    pub const {s}_field_desc: FieldDesc = .{{ .number = {s}, .xor = {s} }};\n",
                .{ desc.name, desc.number, desc.xor orelse "0" },
            );
        }
    }

    try out.writeAll("};\n\n");
}

const Diagnostic = struct {
    where: Placement,
    kind: union(enum) {
        unexpected: Lexer.Token,
        custom: []const u8,
    },

    pub fn unexpected(l: *const Lexer, t: Lexer.Token) Diagnostic {
        return .{
            .where = .extract(l, t.size()),
            .kind = .{ .unexpected = t },
        };
    }

    pub fn custom(l: *const Lexer, t: Lexer.Token, message: []const u8) Diagnostic {
        return .{
            .where = .extract(l, t.size()),
            .kind = .{ .custom = message },
        };
    }

    pub fn customNoToken(l: *const Lexer, width: usize, message: []const u8) Diagnostic {
        return .{
            .where = .extract(l, width),
            .kind = .{ .custom = message },
        };
    }

    pub fn format(d: Diagnostic, w: *Io.Writer) !void {
        try w.print("{s}:{d}:{d}: ", .{ d.where.file, d.where.line, d.where.pos });
        switch (d.kind) {
            .unexpected => |token| {
                try w.print("unexpected {f}\n", .{token});
            },
            .custom => |message| {
                try w.print("{s}\n", .{message});
            },
        }

        try w.print("{s}\n", .{d.where.region});
        try w.splatByteAll(' ', d.where.pos);
        try w.splatByteAll('^', d.where.width);
        try w.writeByte('\n');
    }

    const Placement = struct {
        region: []const u8,
        file: []const u8,
        line: usize,
        pos: usize,
        width: usize,

        fn extract(l: *const Lexer, unit_width: usize) Placement {
            const cur_pos = l.start.len - l.content.len - unit_width;

            const line_end = cur_pos + unit_width + (std.mem.findScalar(u8, l.content, '\n') orelse l.content.len);
            const line_beginning = if (std.mem.findScalarLast(u8, l.start[0..cur_pos], '\n')) |nl| nl + 1 else 0;

            return .{
                .file = l.filename,
                .region = l.start[line_beginning..line_end],
                .line = l.line,
                .pos = cur_pos - line_beginning,
                .width = unit_width,
            };
        }
    };
};

const Lexer = struct {
    filename: []const u8,
    start: []const u8,
    content: []const u8,
    line: usize = 1,

    pub fn init(filename: []const u8, content: []const u8) Lexer {
        return .{ .filename = filename, .start = content, .content = content };
    }

    pub fn isAtEnd(l: *Lexer) bool {
        l.skipWhitespaces();
        return l.content.len == 0;
    }

    pub fn next(l: *Lexer) !?Token {
        if (l.isAtEnd()) return null;

        if (std.enums.fromInt(Token.Punct, l.content[0])) |punct| {
            l.content = l.content[1..];
            return .{ .punct = punct };
        }

        switch (l.content[0]) {
            '-', '0'...'9' => return .{ .number = l.consumeNumber() },
            'a'...'z', 'A'...'Z', '_' => {
                const name = l.consumeName();
                return if (std.meta.stringToEnum(Token.Keyword, name)) |keyword|
                    .{ .keyword = keyword }
                else
                    .{ .name = name };
            },
            '"' => return .{ .quoted = try l.consumeEnclosed('"') },
            else => {
                l.content = l.content[1..];
                std.log.err("{f}", .{Diagnostic.customNoToken(l, 1, "unexpected character")});
                return error.UnexpectedCharacter;
            },
        }
    }

    pub fn expectPunct(l: *Lexer, expected: Token.Punct) !void {
        const p = try l.expect(.punct);
        if (p.punct != expected) {
            std.log.err("{f}", .{Diagnostic.unexpected(l, p)});
            return error.UnexpectedToken;
        }
    }

    pub fn expectPuncts(l: *Lexer, comptime puncts: []const Token.Punct) !Token.Punct.Restricted(puncts) {
        const p = try l.expect(.punct);
        inline for (puncts) |expected|
            if (@intFromEnum(p.punct) == @intFromEnum(expected))
                return @enumFromInt(@intFromEnum(p.punct));

        std.log.err("{f}", .{Diagnostic.unexpected(l, p)});
        return error.UnexpectedToken;
    }

    pub fn expect(l: *Lexer, expected_kind: std.meta.Tag(Token)) !Token {
        const t = try l.next() orelse return error.EndOfFile;

        if (std.meta.activeTag(t) != expected_kind) {
            std.log.err("{f}", .{Diagnostic.unexpected(l, t)});
            return error.UnexpectedToken;
        }

        return t;
    }

    // apparently, field names can consist of keywords...
    pub fn expectNameOrKeyword(l: *Lexer) ![]const u8 {
        switch (try l.next() orelse return error.EndOfFile) {
            .name => |name| return name,
            .keyword => |keyword| return @tagName(keyword),
            else => |t| {
                std.log.err("{f}", .{Diagnostic.unexpected(l, t)});
                return error.UnexpectedToken;
            },
        }
    }

    fn consumeNumber(l: *Lexer) []const u8 {
        const start = l.content;
        l.content = l.content[1..]; // checked in main.zig:0/fn(.)next
        while (l.content.len > 0) : (l.content = l.content[1..]) {
            switch (l.content[0]) {
                '0'...'9' => continue,
                else => break,
            }
        }

        return start[0 .. start.len - l.content.len];
    }

    fn consumeName(l: *Lexer) []const u8 {
        const start = l.content;
        while (l.content.len > 0) : (l.content = l.content[1..]) {
            switch (l.content[0]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => continue,
                else => break,
            }
        }

        return start[0 .. start.len - l.content.len];
    }

    fn consumeEnclosed(l: *Lexer, c: u8) ![]const u8 {
        l.content = l.content[1..]; // checked in main.zig:0/fn(.)next
        const start = l.content;

        while (l.content.len > 0) : (l.content = l.content[1..]) {
            if (l.content[0] == c) break;
        } else return error.UnclosedLiteral;

        l.content = l.content[1..];
        return start[0 .. start.len - l.content.len - 1];
    }

    fn skipWhitespaces(l: *Lexer) void {
        var saw_comment_slash: bool = false; // indicates whether we saw the first '/'
        var skipping_line: bool = false; // indicates if we're skipping the rest of line (due to '//')

        while (l.content.len > 0) : (l.content = l.content[1..]) {
            switch (l.content[0]) {
                ' ', '\r', '\t' => continue,
                '\n' => {
                    l.line += 1;
                    skipping_line = false;
                },
                '/' => if (saw_comment_slash) {
                    saw_comment_slash = false;
                    skipping_line = true;
                } else if (!skipping_line) {
                    saw_comment_slash = true;
                },
                else => if (!skipping_line) break,
            }
        }
    }

    pub const Token = union(enum) {
        number: []const u8,
        name: []const u8,
        quoted: []const u8,
        keyword: Keyword,
        punct: Punct,

        pub const Keyword = enum {
            syntax,
            package,
            import,
            option,
            message,
            @"enum",
            repeated,
            map,
            oneof,
        };

        pub const Punct = enum(u8) {
            semicolon = ';',
            open_curly = '{',
            close_curly = '}',
            equal_sign = '=',
            open_triangle = '<',
            close_triangle = '>',
            comma = ',',
            dot = '.',
            open_paren = '(',
            close_paren = ')',
            open_square = '[',
            close_square = ']',

            pub fn Restricted(comptime variants: []const Punct) type {
                var field_names: []const []const u8 = &.{};
                inline for (variants) |variant|
                    field_names = field_names ++ .{@tagName(variant)};

                var field_values: [field_names.len]u8 = undefined;
                inline for (variants, 0..) |variant, i|
                    field_values[i] = @intFromEnum(variant);

                return @Enum(u8, .exhaustive, field_names, &field_values);
            }
        };

        pub fn size(t: Token) usize {
            return switch (t) {
                .punct => 1,
                .quoted => |string| string.len + 2,
                .number, .name => |content| content.len,
                .keyword => |keyword| switch (keyword) {
                    inline else => |tag| @tagName(tag).len,
                },
            };
        }

        pub fn format(t: Token, w: *Io.Writer) !void {
            switch (t) {
                .punct => |p| try w.print("'{c}'", .{@intFromEnum(p)}),
                .quoted => |s| try w.print("\"{s}\"", .{s}),
                .name, .number => |n| try w.print("'{s}'", .{n}),
                .keyword => |kw| try w.print("'{s}'", .{@tagName(kw)}),
            }
        }
    };
};
