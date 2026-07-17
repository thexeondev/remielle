const remielle = @import("remielle");

const log = std.log.scoped(.@"remielle-dpsv");

pub const Options = struct {
    listen_address: []const u8 = @import("config").listen_address,
    concurrent_connections_limit: u64 = @import("config").concurrent_connections_limit,
};

pub const std_options: std.Options = .{
    .logFn = rmio.log.logFn,
};

pub fn main(init: Init.Minimal) void {
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

    const data = Data.build(arena.allocator()) catch |err| switch (err) {
        error.OutOfMemory => fatal("failed to build static responses", .{}),
    };

    const concurrency_units: Io.Limit = if (options.concurrent_connections_limit != 0)
        // One extra for the initial `io.concurrent`
        .limited64(1 +| options.concurrent_connections_limit)
    else
        .unlimited;

    var io_impl = if (rmio.RemiellIo.supported)
        rmio.RemiellIo.init(heap.page_allocator, .{
            .coroutine_limit = concurrency_units,
            .stack_size = 1024 * 128,
        }) catch |err|
            fatal("failed to init I/O implementation: {t}", .{err})
    else
        Io.Threaded.init(heap.page_allocator, .{ .concurrent_limit = concurrency_units });

    defer io_impl.deinit();
    const io = io_impl.io();

    rmio.splash.print();

    const listen_args = .{ io, &data, &listen_address };

    var app_future = io.concurrent(app.listen, listen_args) catch |concurrent_err| switch (concurrent_err) {
        error.ConcurrencyUnavailable => {
            @call(.auto, app.listen, listen_args) catch |err| switch (err) {
                error.Canceled => unreachable,
            };

            return;
        },
    };

    if (rmio.RemiellIo.supported) {
        io_impl.waitForShutdown();
        app_future.cancel(io) catch {};
    } else {
        app_future.await(io) catch {};
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

const app = @import("app.zig");
const Data = @import("Data.zig");

const std = @import("std");
const rmio = @import("rmio");
const rmcli = @import("rmcli");
