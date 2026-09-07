//! An allocator that can be disabled.
//!
//! Inspired by:
//! https://github.com/tigerbeetle/tigerbeetle/blob/47aeb2212a255273dda508288412e537d11e4b7c/src/static_allocator.zig

const StaticAllocator = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

child_allocator: Allocator,
behavior: std.atomic.Value(Behavior),

const Behavior = enum(u32) {
    allow_all,
    allow_dealloc,
    @"unreachable",
};

pub fn init(child_allocator: Allocator) StaticAllocator {
    return .{
        .child_allocator = child_allocator,
        .behavior = .init(.allow_all),
    };
}

pub fn setBehavior(static_allocator: *StaticAllocator, behavior: Behavior) void {
    static_allocator.behavior.store(behavior, .monotonic);
}

pub fn allocator(static_allocator: *StaticAllocator) Allocator {
    return .{
        .ptr = static_allocator,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

fn alloc(erased: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const context: *StaticAllocator = @ptrCast(@alignCast(erased));
    switch (context.behavior.load(.monotonic)) {
        .allow_all => return context.child_allocator.vtable.alloc(
            context.child_allocator.ptr,
            len,
            alignment,
            ret_addr,
        ),
        .allow_dealloc => unreachable,
        .@"unreachable" => unreachable,
    }
}

fn resize(
    erased: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    const context: *StaticAllocator = @ptrCast(@alignCast(erased));
    switch (context.behavior.load(.monotonic)) {
        .allow_all => return context.child_allocator.vtable.resize(
            context.child_allocator.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        ),
        .allow_dealloc => unreachable,
        .@"unreachable" => unreachable,
    }
}

fn remap(
    erased: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    const context: *StaticAllocator = @ptrCast(@alignCast(erased));
    switch (context.behavior.load(.monotonic)) {
        .allow_all => return context.child_allocator.vtable.remap(
            context.child_allocator.ptr,
            memory,
            alignment,
            new_len,
            ret_addr,
        ),
        .allow_dealloc => unreachable,
        .@"unreachable" => unreachable,
    }
}

fn free(
    erased: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    ret_addr: usize,
) void {
    const context: *StaticAllocator = @ptrCast(@alignCast(erased));
    switch (context.behavior.load(.monotonic)) {
        .allow_all, .allow_dealloc => context.child_allocator.vtable.free(
            context.child_allocator.ptr,
            memory,
            alignment,
            ret_addr,
        ),
        .@"unreachable" => unreachable,
    }
}
