const builtin = @import("builtin");
const is_debug = builtin.mode == .debug;

const std = @import("std");

const Io = std.Io;
const net = std.Io.net;
const process = std.process;

const remielle = @import("remielle");

const app = @import("app.zig");

const log = std.log.scoped(.@"remielle-sdksv");

pub const std_options: std.Options = .{
    .logFn = remielle.log.logFn,
};

pub const Args = struct {
    @"--listen-address": []const u8 = @import("config").listen_address,
};

pub fn usage(io: Io) noreturn {
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

pub fn main(init: process.Init.Minimal) void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const gpa = if (is_debug)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

    var io_impl = if (remielle.io.Evented.supported)
        remielle.io.Evented.init(gpa, .{
            .coroutine_limit = .unlimited, // TODO
            .stack_size = 1024 * 512,
        }) catch |err|
            fatal("failed to init I/O implementation: {t}", .{err})
    else
        Io.Threaded.init(gpa, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });

    defer io_impl.deinit();
    const io = io_impl.io();

    const args_slice = init.args.toSlice(arena.allocator()) catch |err|
        fatal("failed to collect cli arguments: {t}", .{err});

    const args = remielle.args.parse(Args, log, args_slice) orelse usage(io);

    const listen_address = net.IpAddress.parseLiteral(args.@"--listen-address") catch |err|
        fatal("bad listen address specified: {t}", .{err});

    remielle.splash.print();

    const listen_args = .{ io, gpa, &listen_address };

    var listen = io.concurrent(app.listen, listen_args) catch |err|
        fatal("failed to start: {t}", .{err});
    defer listen.cancel(io) catch {};

    if (remielle.io.Evented.supported) {
        io_impl.waitForShutdown();
    } else {
        listen.await(io) catch {};
    }
}

inline fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}
