const remielle = @import("remielle");

const log = std.log.scoped(.@"remielle-sdksv");

pub const Options = struct {
    listen_address: []const u8 = @import("config").listen_address,
    concurrent_connections_limit: u64 = @import("config").concurrent_connections_limit,
};

pub const std_options: std.Options = .{
    .logFn = rmio.log.logFn,
};

pub fn main(init: Init.Minimal) void {
    var debug_allocator: heap.DebugAllocator(.{}) = .init;
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const gpa = if (is_debug)
        debug_allocator.allocator()
    else
        heap.smp_allocator;

    var arena: heap.ArenaAllocator = .init(heap.page_allocator);

    const args = init.args.toSlice(arena.allocator()) catch |err|
        fatal("failed to collect cli arguments: {t}", .{err});

    var options_err: remielle.cli.ErrorDescription = undefined;
    const options = remielle.cli.parseOptions(Options, args[1..], &options_err) orelse fatal(
        "{f}\nusage: {s} {f}",
        .{ options_err, args[0], remielle.cli.Usage(Options) },
    );

    const listen_address = net.IpAddress.parseLiteral(options.listen_address) catch |err|
        fatal("bad listen address specified: {t}", .{err});

    const concurrency_units: Io.Limit = if (options.concurrent_connections_limit != 0)
        // One extra for the initial `io.concurrent`
        .limited64(1 +| options.concurrent_connections_limit)
    else
        .unlimited;

    var io_impl = if (rmio.RemiellIo.supported)
        rmio.RemiellIo.init(heap.page_allocator, .{
            .coroutine_limit = concurrency_units,
            .stack_size = 1024 * 512,
        }) catch |err|
            fatal("failed to init I/O implementation: {t}", .{err})
    else
        Io.Threaded.init(heap.page_allocator, .{ .concurrent_limit = concurrency_units });

    defer io_impl.deinit();
    const io = io_impl.io();

    rmio.splash.print();

    const listen_args = .{ io, gpa, &listen_address };

    var listen = io.concurrent(app.listen, listen_args) catch |concurrent_err| switch (concurrent_err) {
        error.ConcurrencyUnavailable => {
            @call(.auto, app.listen, listen_args) catch |err| switch (err) {
                error.Canceled => unreachable,
            };

            return;
        },
    };

    if (rmio.RemiellIo.supported) {
        io_impl.waitForShutdown();
        listen.cancel(io) catch {};
    } else {
        listen.await(io) catch {};
    }
}

inline fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

const Io = std.Io;
const Init = std.process.Init;

const heap = std.heap;
const net = std.Io.net;

const is_debug = builtin.mode == .Debug;

const app = @import("app.zig");

const rmio = @import("rmio");
const builtin = @import("builtin");
const std = @import("std");
