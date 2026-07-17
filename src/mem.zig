const std = @import("std");
const heap = std.heap;

pub fn LimitedString(comptime limit: usize) type {
    return struct {
        const String = @This();

        pub const Error = error{TooLongString};

        pub const max_length = limit;
        pub const empty: String = .{};

        bytes: [max_length + 1]u8 = @splat(0),

        pub fn fromSlice(value: []const u8) Error!String {
            var string: String = .{};
            try string.set(value);

            return string;
        }

        pub fn constant(comptime value: []const u8) String {
            return comptime String.fromSlice(value) catch
                unreachable; // Constant string is too long.
        }

        pub fn view(string: *const String) [:0]const u8 {
            std.debug.assert(string.bytes[max_length] == 0);
            return std.mem.span(@as([*:0]const u8, @ptrCast(&string.bytes)));
        }

        pub fn set(string: *String, value: []const u8) Error!void {
            if (value.len > max_length) return error.TooLongString;

            @memcpy(string.bytes[0..value.len], value);
            string.bytes[value.len] = 0;
        }
    };
}

/// Deprecated.
fn SoaBucket(comptime capacity: usize, comptime Struct: type) type {
    const struct_info = @typeInfo(Struct).@"struct";

    var field_names: [struct_info.fields.len][]const u8 = undefined;
    var field_types: [struct_info.fields.len]type = undefined;

    inline for (struct_info.fields, &field_names, &field_types) |struct_field, *field_name, *field_type| {
        field_name.* = struct_field.name;

        field_type.* = switch (struct_field.type) {
            bool => std.StaticBitSet(capacity),
            else => |Field| switch (@typeInfo(Field)) {
                .bool => unreachable,
                .int, .float, .array, .@"struct", .@"enum", .@"union", .pointer => [capacity]Field,
                else => @compileError("you're holding it wrong"),
            },
        };
    }

    return @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
}

/// Deprecated.
pub fn suggestBucketSize(comptime desired_size: usize, comptime Struct: type) usize {
    const desired_bytes = @sizeOf(SoaBucket(desired_size, Struct));
    if (desired_bytes % heap.page_size_min == 0)
        return desired_size;

    const desired_pages = std.math.divCeil(usize, desired_bytes, heap.page_size_min) catch unreachable;
    var suggested_size = desired_size;

    while (std.math.divCeil(
        usize,
        @sizeOf(SoaBucket(suggested_size + 1, Struct)),
        heap.page_size_min,
    ) catch unreachable == desired_pages) : (suggested_size += 1) {}

    return suggested_size;
}

/// Deprecated.
pub fn RemielleArrayList(
    comptime bucket_size: usize,
    comptime Struct: type,
    comptime Index: type,
) type {
    const enum_indexing: bool = comptime switch (@typeInfo(Index)) {
        .int => |int| int: {
            std.debug.assert(int.signedness == .unsigned);
            break :int false;
        },
        .@"enum" => |enumeration| enumeration: {
            std.debug.assert(!enumeration.is_exhaustive);
            break :enumeration true;
        },
        else => @compileError("invalid index type: " ++ @typeName(Index)),
    };

    return struct {
        const List = @This();

        pub const Bucket = SoaBucket(bucket_size, Struct);

        pub const bucket_capacity = bucket_size;

        // We're using ArrayList instead of linked lists to achieve O(1) indexing.
        // A new bucket insertion is a rare operation, so nobody cares about it being not O(1).
        // Keep in mind that we're storing pointers here, so even the worst case appending to it
        // won't result in copying/relocating all bucket data.
        buckets: std.ArrayList(*Bucket),
        item_count: usize,

        pub const empty: List = .{ .buckets = .empty, .item_count = 0 };

        pub inline fn capacity(list: *const List) usize {
            return list.buckets.items.len * bucket_size;
        }

        pub fn addOne(list: *List) MapError!Index {
            if (list.item_count == list.capacity())
                try list.mapBucket();

            defer list.item_count += 1;
            return if (enum_indexing) @enumFromInt(list.item_count) else @intCast(list.item_count);
        }

        pub inline fn get(
            list: *const List,
            comptime field_name: @EnumLiteral(),
            index: Index,
        ) @FieldType(Struct, @tagName(field_name)) {
            @setRuntimeSafety(false); // implicit boundary checks are for amateurs

            const i = intFromIndex(index);

            const bucket = list.buckets.items[@divFloor(i, bucket_size)];
            return switch (@FieldType(Struct, @tagName(field_name))) {
                bool => @field(bucket, @tagName(field_name)).isSet(i % bucket_size),
                else => @field(bucket, @tagName(field_name))[i % bucket_size],
            };
        }

        pub inline fn getPtr(
            list: *List,
            comptime field_name: @EnumLiteral(),
            index: Index,
        ) *@FieldType(Struct, @tagName(field_name)) {
            @setRuntimeSafety(false); // implicit boundary checks are for amateurs

            const i = intFromIndex(index);

            const bucket = list.buckets.items[@divFloor(i, bucket_size)];
            return switch (@FieldType(Struct, @tagName(field_name))) {
                bool => @compileError("if you need mutable access, use `swapBit` instead, otherwise `get`"),
                else => &(@field(bucket, @tagName(field_name))[i % bucket_size]),
            };
        }

        pub fn swapBit(
            list: *List,
            comptime field_name: @EnumLiteral(),
            index: Index,
            value: bool,
        ) bool {
            @setRuntimeSafety(false); // implicit boundary checks are for amateurs

            const i = intFromIndex(index);

            const bucket = list.buckets.items[@divFloor(i, bucket_size)];
            const bit_set = &@field(bucket, @tagName(field_name));
            const old_value = bit_set.isSet(i % bucket_size);
            bit_set.setValue(i % bucket_size, value);

            return old_value;
        }

        pub const MapError = error{
            MappingFailed,
        };

        /// Maps one bucket.
        pub fn mapBucket(list: *List) MapError!void {
            const page = heap.PageAllocator.map(@sizeOf(Bucket), .of(Bucket)) orelse
                return error.MappingFailed;

            const bucket: *Bucket = @ptrCast(@alignCast(page));

            if (list.buckets.capacity == 0) list.buckets.ensureTotalCapacity(
                heap.page_allocator,
                @divFloor(heap.page_size_min, @sizeOf(usize)),
            ) catch
                return error.MappingFailed;

            list.buckets.append(heap.page_allocator, bucket) catch
                return error.MappingFailed;
        }

        pub fn swapRemove(list: *List, index: Index) void {
            @setRuntimeSafety(false); // implicit boundary checks are for amateurs

            const remove_at_bucket = list.buckets.items[@divFloor(intFromIndex(index), bucket_size)];
            const last_bucket = list.buckets.items[@divFloor(list.item_count - 1, bucket_size)];

            const remove_at = intFromIndex(index) % bucket_size;
            const last = (list.item_count - 1) % bucket_size;

            inline for (@typeInfo(Struct).@"struct".fields) |field| switch (field.type) {
                bool => @field(remove_at_bucket, field.name).setValue(
                    remove_at,
                    @field(last_bucket, field.name).isSet(last),
                ),
                else => @field(remove_at_bucket, field.name)[remove_at] = @field(last_bucket, field.name)[last],
            };

            list.item_count -= 1;
        }

        inline fn intFromIndex(index: Index) usize {
            return if (enum_indexing) @intFromEnum(index) else index;
        }
    };
}
