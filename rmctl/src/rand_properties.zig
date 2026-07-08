const table: Table = .init(.{
    .{ 11103, &.{1}, 550, 112 },
    .{ 11102, &.{ 4, 5, 6 }, 750, 300 },
    .{ 12103, &.{2}, 79, 19 },
    .{ 12102, &.{ 4, 5, 6 }, 750, 300 },
    .{ 13103, &.{3}, 46, 15 },
    .{ 13102, &.{ 4, 5, 6 }, 1200, 480 },
    .{ 23203, &.{}, 0, 9 },
    .{ 23103, &.{5}, 600, null },
    .{ 31402, &.{6}, 750, null },
    .{ 31203, &.{4}, 23, 9 },
    .{ 21103, &.{4}, 1200, 480 },
    .{ 20103, &.{4}, 600, 240 },
    .{ 30502, &.{6}, 1500, null },
    .{ 12202, &.{6}, 450, null },
    .{ 31803, &.{5}, 750, null },
    .{ 31903, &.{5}, 750, null },
    .{ 31603, &.{5}, 750, null },
    .{ 31703, &.{5}, 750, null },
    .{ 31503, &.{5}, 750, null },
    .{ 32303, &.{5}, 750, null },
});

const Table = struct {
    const count = 20;

    keys: [count]u16,
    main_property_slots: [count][]const u8,
    main_base_value: [count]u16,
    rand_base_value: [count]?u16,

    pub fn init(values: [count]struct { u16, []const u8, u16, ?u16 }) Table {
        var t: Table = undefined;

        for (
            values,
            &t.keys,
            &t.main_property_slots,
            &t.main_base_value,
            &t.rand_base_value,
        ) |value, *key, *main_slots, *main_base_value, *rand_base_value| {
            key.* = value[0];
            main_slots.* = value[1];
            main_base_value.* = value[2];
            rand_base_value.* = value[3];
        }

        return t;
    }
};

pub fn fill(random: Random, slot: u8, out: *[5]CreateEquip.Entry.Property) void {
    var properties_buf: [Table.count]usize = undefined;
    var main_properties: std.ArrayList(usize) = .initBuffer(&properties_buf);

    for (&table.main_property_slots, 0..) |main_property_slots, i| {
        if (std.mem.findScalar(u8, main_property_slots, slot) != null)
            main_properties.appendAssumeCapacity(i);
    }

    const main_property_i = main_properties.items[random.int(u8) % main_properties.items.len];

    out[0] = .{
        .key = @intCast(table.keys[main_property_i]),
        .base_value = @intCast(table.main_base_value[main_property_i]),
        .add_value = 1,
    };

    var select_rand_properties: std.ArrayList(usize) = .initBuffer(&properties_buf);

    for (&table.rand_base_value, 0..) |rand_base_value, i| {
        if (rand_base_value == null) continue;
        if (i == main_property_i) continue;

        select_rand_properties.appendAssumeCapacity(i);
    }

    var add_value_mod: u8 = 5;

    for (out[1..], 1..) |*property, index| {
        const selected = random.int(u8) % select_rand_properties.items.len;
        const rand_i = select_rand_properties.items[selected];

        const add_value = if (index == out.len - 1)
            add_value_mod
        else
            random.int(u8) % add_value_mod;

        add_value_mod -= add_value;

        property.* = .{
            .key = table.keys[rand_i],
            .base_value = @intCast(table.rand_base_value[rand_i].?),
            .add_value = @intCast(1 + add_value),
        };

        _ = select_rand_properties.swapRemove(selected);
    }
}

const Random = std.Random;
const CreateEquip = rmnet.Operation.CreateEquip;

const rmnet = @import("rmnet");
const std = @import("std");
