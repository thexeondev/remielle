const builtin = @import("builtin");
const is_debug = builtin.mode == .debug;

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const process = std.process;
const DefaultCsprng = std.Random.DefaultCsprng;

const remielle = @import("remielle");
const assets = remielle.assets;

const app = @import("app.zig");
const Server = @import("Server.zig");

const log = std.log.scoped(.@"remielle-gamesv");

pub const Args = struct {
    @"--game-bind-address": []const u8 = @import("config").game_bind_address,
    @"--ctl-bind-address": []const u8 = @import("config").ctl_bind_address,
    @"--require-secure-random": bool = true,
};

pub const std_options: std.Options = .{
    .logFn = remielle.log.logFn,
};

pub fn usage(io: Io) noreturn {
    const defaults: Args = .{};

    Io.File.stdout().writeStreamingAll(io, std.fmt.comptimePrint(
        \\Usage: remielle-gamesv [options]
        \\
        \\Options:
        \\  --help, -h                Print this help and exit
        \\  --game-bind-address       UDP address for game clients; default is {q}
        \\  --ctl-bind-address        UDP address for ctl clients; default is {q}
        \\  --require-secure-random   Whether to abort on entropy unavailability; default is {any}
        \\
    , .{
        defaults.@"--game-bind-address",
        defaults.@"--ctl-bind-address",
        defaults.@"--require-secure-random",
    })) catch {};
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
    defer if (is_debug) arena.deinit();

    var io_impl = if (remielle.io.RemiellIo.supported)
        remielle.io.RemiellIo.init(gpa, .{ .coroutine_limit = .unlimited, .stack_size = 1024 * 1024 }) catch |err|
            fatal("failed to init I/O implementation: {t}", .{err})
    else
        std.Io.Threaded.init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    const args_slice = init.args.toSlice(arena.allocator()) catch |err|
        fatal("failed to collect cli arguments: {t}", .{err});

    const args = remielle.args.parse(Args, log, args_slice) orelse usage(io);

    var addresses: [Server.Socket.count]net.IpAddress = undefined;

    addresses[Server.Socket.game.toIndex()] =
        net.IpAddress.parseLiteral(args.@"--game-bind-address") catch |err|
            fatal("bad game bind address specified: {t}", .{err});

    addresses[Server.Socket.control.toIndex()] =
        net.IpAddress.parseLiteral(args.@"--ctl-bind-address") catch |err|
            fatal("bad ctl bind address specified: {t}", .{err});

    remielle.splash.print();

    var csprng_seed: [DefaultCsprng.secret_seed_length]u8 = undefined;
    io.randomSecure(&csprng_seed) catch |err| switch (err) {
        error.Canceled => unreachable, // no
        error.EntropyUnavailable => if (args.@"--require-secure-random")
            fatal("secure entropy source is uavailable", .{})
        else
            io.random(&csprng_seed),
    };

    var csprng_impl: DefaultCsprng = .init(csprng_seed);
    const csprng = csprng_impl.random();

    var asset_lookup = assets.Lookup.init(gpa) catch |err| switch (err) {
        error.OutOfMemory => fatal("out of memory", .{}),
    };
    defer asset_lookup.deinit(gpa);

    const bind_args = .{ io, gpa, csprng, &asset_lookup, &addresses, .unlimited };

    var app_future = io.concurrent(app.bind, bind_args) catch |err|
        fatal("failed to start: {t}", .{err});
    defer app_future.cancel(io) catch {};

    if (remielle.io.RemiellIo.supported) {
        io_impl.waitForShutdown();
    } else {
        app_future.await(io) catch {};
    }
}

inline fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    process.exit(1);
}
