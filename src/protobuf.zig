const std = @import("std");
const Io = std.Io;
const Type = std.builtin.Type;
const Allocator = std.mem.Allocator;

/// Main protocol types. Stable.
pub const main = @import("protobuf/pb.main.zig");

/// Protobuf descriptors for main protocol types. Unstable.
pub const main_desc = @import("protobuf/pb.main.desc.zig");

/// Exports a subset of protocol types with their descriptors baked in. Stable.
pub const stable = @import("protobuf/pb.stable.zig");

pub const features = @import("protobuf/features.zig");

pub const Descriptors = enum {
    main,
    stable,

    pub inline fn namespace(comptime set: Descriptors) type {
        return switch (set) {
            .main => main_desc,
            .stable => stable,
        };
    }

    pub inline fn describe(comptime set: Descriptors, comptime M: type) ?Message {
        const ns = set.namespace();

        if (!@hasDecl(M, "pb_desc_name"))
            return .{ .namespace = ns, .descriptor = M };

        if (!@hasDecl(ns, M.pb_desc_name))
            return null;

        return .{ .namespace = ns, .descriptor = @field(ns, M.pb_desc_name) };
    }

    pub inline fn getDescriptorByName(comptime set: Descriptors, comptime name: []const u8) ?Message {
        const ns = set.namespace();

        return if (@hasDecl(ns, name))
            .{ .namespace = ns, .descriptor = @field(ns, name) }
        else
            null;
    }

    pub const Message = struct {
        namespace: type,
        descriptor: type,

        pub inline fn field(comptime m: Message, comptime name: []const u8) ?Field {
            const field_desc_name = name ++ "_field_desc";
            const field_desc = if (@hasDecl(m.descriptor, field_desc_name))
                @field(m.descriptor, field_desc_name)
            else
                return null;

            return .{
                .namespace = m.namespace,
                .number = @intCast(field_desc.number),
                .xor = field_desc.xor,
            };
        }

        pub inline fn hasField(comptime m: Message, comptime name: []const u8) bool {
            return @hasDecl(m.descriptor, name ++ "_field_desc");
        }
    };

    pub const Field = struct {
        namespace: type,
        number: u29,
        xor: u32,
    };
};

pub inline fn cmdId(comptime M: type) ?u16 {
    return if (Descriptors.main.describe(M)) |desc|
        desc.descriptor.cmd_id
    else
        null;
}

const WireType = enum(u3) {
    var_int = 0,
    int64 = 1,
    length_prefixed = 2,
    int32 = 5,
    _,

    pub fn of(comptime T: type) WireType {
        return switch (T) {
            u32, i32, u64, i64, bool => .var_int,
            f32 => .int32,
            f64 => .int64,
            []const u8 => .length_prefixed,
            else => switch (@typeInfo(T)) {
                .@"enum" => .var_int,
                .@"struct" => .length_prefixed,
                .optional, .pointer => |container| of(container.child),
                else => @compileError("unsupported type: " ++ @typeName(T)),
            },
        };
    }
};

const WireTag = packed struct(u32) {
    type: WireType,
    number: u29,
};

pub fn encodingLength(comptime desc_set: Descriptors, message: anytype) u64 {
    var buf: [128]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&buf);
    encode(desc_set, &discarding.writer, message) catch unreachable;

    return discarding.fullCount();
}

pub fn encodeAlloc(
    comptime desc_set: Descriptors,
    arena: Allocator,
    message: anytype,
) Allocator.Error![]const u8 {
    var allocating: Io.Writer.Allocating = .init(arena);
    errdefer allocating.deinit();

    encode(desc_set, &allocating.writer, message) catch
        return error.OutOfMemory;

    return allocating.written();
}

pub fn encode(comptime desc_set: Descriptors, writer: *Io.Writer, message: anytype) Io.Writer.Error!void {
    const Message = @TypeOf(message);
    const descriptor = desc_set.describe(Message) orelse
        return;

    const struct_info = @typeInfo(Message).@"struct";
    @setEvalBranchQuota(struct_info.fields.len * struct_info.fields.len);

    inline for (struct_info.fields) |struct_field| switch (FieldKind.of(struct_field.type)) {
        .single => try encodeField(
            desc_set,
            descriptor.field(struct_field.name) orelse continue,
            writer,
            @field(message, struct_field.name),
        ),
        .oneof => if (@field(message, struct_field.name)) |oneof| switch (oneof) {
            inline else => |value, tag| try encodeField(
                desc_set,
                descriptor.field(@tagName(tag)) orelse continue,
                writer,
                value,
            ),
        },
    };
}

fn encodeField(
    comptime desc_set: Descriptors,
    comptime descriptor: Descriptors.Field,
    writer: *Io.Writer,
    value: anytype,
) Io.Writer.Error!void {
    const Value = @TypeOf(value);
    switch (comptime ValueKind.of(Value)) {
        .regular => {
            const wt: WireTag = .{ .type = .of(Value), .number = descriptor.number };
            try writeVarInt(writer, u32, @bitCast(wt));

            switch (Value) {
                bool => try writeVarInt(writer, u8, @intFromBool(value)),
                i32, i64, u32, u64 => |Int| try writeVarInt(writer, Int, value ^ descriptor.xor),
                f32 => try writer.writeInt(u32, @bitCast(value), .little),
                f64 => try writer.writeInt(u64, @bitCast(value), .little),
                []const u8 => {
                    try writeVarInt(writer, u64, value.len);
                    try writer.writeAll(value);
                },
                else => switch (@typeInfo(Value)) {
                    .@"enum" => try writeVarInt(writer, i32, @intFromEnum(value)),
                    .@"struct" => {
                        const length = encodingLength(desc_set, value);
                        try writeVarInt(writer, u64, length);
                        try encode(desc_set, writer, value);
                    },
                    else => @compileError("unsupported type: " ++ @typeName(Value)),
                },
            }
        },
        .optional => if (value) |child|
            try encodeField(desc_set, descriptor, writer, child),
        .repeated => for (value.items) |item|
            try encodeField(desc_set, descriptor, writer, item),
    }
}

fn writeVarInt(writer: *Io.Writer, comptime Int: type, value: Int) Io.Writer.Error!void {
    var v: @Int(.unsigned, @typeInfo(Int).int.bits) = @bitCast(value);

    while (true) : (v >>= 7) {
        const byte: VByte = .{ .value = @truncate(v), .continuation = v >= 0x80 };
        try writer.writeByte(@bitCast(byte));

        if (!byte.continuation) break;
    }
}

pub const DecodeError = error{
    Malformed,
} || Allocator.Error || Io.Reader.Error;

pub fn decode(
    comptime desc_set: Descriptors,
    comptime Message: type,
    arena: Allocator,
    reader: *Io.Reader,
) DecodeError!Message {
    const descriptor = comptime desc_set.describe(Message) orelse
        return .init;

    const struct_info = @typeInfo(Message).@"struct";
    comptime var field_count: u32 = 0;

    const FieldNumber = comptime FieldNumber: {
        var field_names: [struct_info.fields.len][:0]const u8 = undefined;
        var field_numbers: [struct_info.fields.len]u32 = undefined;

        for (struct_info.fields) |struct_field| {
            const field_name = struct_field.name;
            const field_desc = descriptor.field(field_name) orelse
                continue;

            field_names[field_count] = field_name;
            field_numbers[field_count] = field_desc.number;

            field_count += 1;
        }

        break :FieldNumber @Enum(u32, .exhaustive, field_names[0..field_count], field_numbers[0..field_count]);
    };

    if (field_count == 0) return .init;

    comptime var oneof_names: [struct_info.fields.len][:0]const u8 = undefined;
    comptime var oneof_types: [struct_info.fields.len]type = undefined;
    comptime var oneof_count: u32 = 0;

    inline for (struct_info.fields) |struct_field| switch (FieldKind.of(struct_field.type)) {
        .single => continue,
        .oneof => {
            oneof_names[oneof_count] = struct_field.name;
            oneof_types[oneof_count] = struct_field.type;
            oneof_count += 1;
        },
    };

    var message: Message = .init;

    while (readVarInt(u32, reader)) |wt_int| {
        const wt: WireTag = @bitCast(wt_int);
        const number = std.enums.fromInt(FieldNumber, wt.number) orelse {
            try skipField(wt.type, reader);
            continue;
        };

        switch (number) {
            inline else => |n| {
                const field_name = @tagName(n);

                if (@hasField(Message, field_name) and
                    comptime FieldKind.of(@FieldType(Message, field_name)) == .single)
                {
                    const Value = @FieldType(Message, field_name);
                    const field_desc = descriptor.field(field_name).?;

                    switch (comptime ValueKind.of(Value)) {
                        .regular, .optional => |V| @field(message, field_name) = try decodeValue(
                            V,
                            desc_set,
                            field_desc,
                            arena,
                            reader,
                        ),
                        .repeated => |Item| {
                            if ((comptime WireType.of(Item) != .length_prefixed) and
                                wt.type == .length_prefixed) try decodePackedValues(
                                Item,
                                desc_set,
                                field_desc,
                                arena,
                                reader,
                                &@field(message, field_name),
                            ) else {
                                const item = try decodeValue(Item, desc_set, field_desc, arena, reader);
                                try @field(message, field_name).append(arena, item);
                            }
                        },
                    }
                }
            },
        }
    } else |err| switch (err) {
        error.EndOfStream => return message,
        else => |e| return e,
    }
}

fn decodePackedValues(
    comptime Value: type,
    comptime desc_set: Descriptors,
    comptime field_desc: Descriptors.Field,
    arena: Allocator,
    reader: *Io.Reader,
    destination: *std.ArrayList(Value),
) DecodeError!void {
    const limit: Io.Limit = .limited(try readVarInt(u32, reader));
    var buf: [128]u8 = undefined;
    var limited = reader.limited(limit, &buf);

    while (decodeValue(Value, desc_set, field_desc, arena, &limited.interface)) |value|
        try destination.append(arena, value)
    else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
}

fn decodeValue(
    comptime Value: type,
    comptime desc_set: Descriptors,
    comptime descriptor: Descriptors.Field,
    arena: Allocator,
    reader: *Io.Reader,
) DecodeError!Value {
    return switch (Value) {
        []const u8 => bytes: {
            const length = try readVarInt(u32, reader);
            break :bytes try reader.readAlloc(arena, length);
        },
        i32, u32, i64, u64 => |Int| int: {
            const value = try readVarInt(u64, reader) ^ descriptor.xor;

            break :int switch (Int) {
                u64 => value,
                i64 => @bitCast(value),
                i32 => std.math.cast(i32, @as(i64, @bitCast(value))) orelse return error.Malformed,
                u32 => std.math.cast(u32, value) orelse return error.Malformed,
                else => comptime unreachable,
            };
        },
        bool => try readVarInt(u8, reader) != 0,
        f32 => @bitCast(try reader.takeInt(u32, .little)),
        f64 => @bitCast(try reader.takeInt(u64, .little)),
        else => switch (@typeInfo(Value)) {
            .@"enum" => enumeration: {
                const value = try readVarInt(i32, reader);
                break :enumeration std.enums.fromInt(Value, value) orelse @enumFromInt(0);
            },
            .@"struct" => message: {
                const limit: Io.Limit = .limited(try readVarInt(u32, reader));

                var buf: [128]u8 = undefined;
                var limited = reader.limited(limit, &buf);

                break :message try decode(desc_set, Value, arena, &limited.interface);
            },
            else => @compileError("unsupported type: " ++ @typeName(Value)),
        },
    };
}

const ReadVarIntError = error{Malformed} || Io.Reader.Error;

fn readVarInt(comptime Int: type, r: *Io.Reader) ReadVarIntError!Int {
    var shift: std.math.Log2Int(Int) = 0;
    var result: Int = 0;

    while (true) : (shift += 7) {
        const byte: VByte = @bitCast(try r.takeByte());
        result |= @as(Int, @intCast(byte.value)) << shift;
        if (!byte.continuation)
            return result;

        if (shift >= @bitSizeOf(Int) - 7) return error.Malformed;
    }
}

fn skipField(ty: WireType, r: *Io.Reader) DecodeError!void {
    switch (ty) {
        .var_int => _ = try readVarInt(u64, r),
        .int32 => try r.discardAll(4),
        .int64 => try r.discardAll(8),
        .length_prefixed => {
            const length = try readVarInt(u64, r);
            try r.discardAll(length);
        },
        _ => return error.Malformed,
    }
}

fn skipMessage(r: *Io.Reader) DecodeError!void {
    while (readVarInt(r, u32)) |raw_wt| {
        const wt: WireTag = @bitCast(raw_wt);
        try skipField(wt.type, r);
    } else |err| switch (err) {
        error.EndOfStream => return,
        else => |e| return e,
    }
}

const VByte = packed struct(u8) {
    value: u7,
    continuation: bool,
};

const ValueKind = union(enum) {
    regular: type,
    repeated: type,
    optional: type,

    pub fn of(comptime Value: type) ValueKind {
        return switch (@typeInfo(Value)) {
            .@"struct" => if (@hasField(Value, "items")) switch (@typeInfo(@FieldType(Value, "items"))) {
                .pointer => |ptr| if (Value == std.ArrayList(ptr.child))
                    .{ .repeated = ptr.child }
                else
                    .{ .regular = Value },
                else => .{ .regular = Value },
            } else .{ .regular = Value },
            .optional => |optional| .{ .optional = optional.child },
            else => .{ .regular = Value },
        };
    }
};

const FieldKind = union(enum) {
    single: void,
    oneof: Type.Union,

    fn of(comptime T: type) FieldKind {
        return switch (@typeInfo(T)) {
            .optional => |optional| switch (@typeInfo(optional.child)) {
                .@"union" => |u| .{ .oneof = u },
                else => .single,
            },
            else => .single,
        };
    }
};
