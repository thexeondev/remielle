const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const process = std.process;
const Threaded = std.Io.Threaded;

const remielle = @import("remielle");
const Evented = remielle.io.Evented;

const app = @import("app.zig");

const log = std.log.scoped(.@"remielle-sdksv");

pub const std_options: std.Options = .{
    .logFn = remielle.log.logFn,
};

var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});

const use_safe_allocator = switch (builtin.optimize) {
    .debug, .safe => true,
    .small, .fast => false,
};

var evented_instance: Evented = undefined;
var threaded_instance: Threaded = undefined;

const io_mode: remielle.io.Mode = .configured;

const Args = struct {
    @"--listen-address": []const u8 = @import("config").listen_address,
};

fn usage(io: Io) noreturn {
    const defaults: Args = .{};

    Io.File.stdout().writeStreamingAll(io, std.fmt.comptimePrint(
        \\Usage: remielle-sdksv [options]
        \\
        \\Options:
        \\  --help, -h        Print this help and exit
        \\  --listen-address  TCP listen address; default is {q}
        \\
    , .{defaults.@"--listen-address"})) catch {};
    process.exit(0);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

pub fn main(init: process.Init.Minimal) !void {
    const gpa = if (use_safe_allocator) safe_allocator.allocator() else std.heap.smp_allocator;
    defer if (use_safe_allocator) {
        _ = safe_allocator.deinit();
    };

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

    const io = switch (io_mode) {
        .evented => evented: {
            evented_instance = try .init(gpa, .{
                .coroutine_limit = .unlimited,
                .stack_size = 1024 * 512,
            });

            break :evented evented_instance.io();
        },
        .threaded => threaded: {
            threaded_instance = .init(gpa, .{
                .argv0 = .init(init.args),
                .environ = init.environ,
            });

            break :threaded threaded_instance.io();
        },
    };

    defer switch (io_mode) {
        .evented => evented_instance.deinit(),
        .threaded => threaded_instance.deinit(),
    };

    const args_slice = try init.args.toSlice(arena.allocator());
    const args = remielle.args.parse(Args, log, args_slice) orelse usage(io);

    const listen_address = net.IpAddress.parseLiteral(args.@"--listen-address") catch |err|
        fatal("bad listen address specified: {t}", .{err});

    remielle.splash.print();

    var listen = try io.concurrent(app.listen, .{ io, gpa, &listen_address });
    defer listen.cancel(io) catch {};

    switch (io_mode) {
        .evented => evented_instance.waitForShutdown(),
        .threaded => remielle.io.waitForShutdownThreaded(&threaded_instance),
    }
}
