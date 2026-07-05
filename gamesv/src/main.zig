const log = std.log.scoped(.@"remielle-gamesv");

pub const Options = struct {
    bind_address_game: []const u8 = @import("config").game_bind_address,
    Bind_address_ctl: []const u8 = @import("config").ctl_bind_address,
    concurrent_sessions_limit: u32 = @import("config").concurrent_sessions_limit,
    insecure_random_allowed: bool = false,
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

    var arena: heap.ArenaAllocator = .init(gpa);
    defer if (is_debug) arena.deinit();

    const args = init.args.toSlice(arena.allocator()) catch |err|
        fatal("failed to collect cli arguments: {t}", .{err});

    var options_err: rmcli.opt.ErrorDescription = undefined;
    const options = rmcli.opt.parse(Options, args[1..], &options_err) orelse fatal(
        "{f}\nusage: {s} {f}",
        .{ options_err, args[0], rmcli.opt.Usage(Options) },
    );

    var addresses: [Server.Socket.count]net.IpAddress = undefined;

    addresses[Server.Socket.game.toIndex()] = net.IpAddress.parseLiteral(options.bind_address_game) catch |err|
        fatal("bad game bind address specified: {t}", .{err});

    addresses[Server.Socket.control.toIndex()] = net.IpAddress.parseLiteral(options.Bind_address_ctl) catch |err|
        fatal("bad ctl bind address specified: {t}", .{err});

    var io_impl = if (rmio.RemiellIo.supported)
        rmio.RemiellIo.init(gpa, .{ .coroutine_limit = .unlimited, .stack_size = 1024 * 1024 }) catch |err|
            fatal("failed to init I/O implementation: {t}", .{err})
    else
        std.Io.Threaded.init(gpa, .{});

    defer io_impl.deinit();
    const io = io_impl.io();

    rmio.splash.print();

    var csprng_seed: [DefaultCsprng.secret_seed_length]u8 = undefined;
    io.randomSecure(&csprng_seed) catch |err| switch (err) {
        error.Canceled => unreachable, // no
        error.EntropyUnavailable => if (options.insecure_random_allowed) {
            io.random(&csprng_seed);
        } else fatal("failed to collect entropy", .{}),
    };

    var csprng_impl: DefaultCsprng = .init(csprng_seed);
    const csprng = csprng_impl.random();

    const concurrent_sessions_limit: Io.Limit = switch (options.concurrent_sessions_limit) {
        0 => .unlimited,
        else => |limit| .limited64(limit),
    };

    var assets = Assets.init(gpa) catch |err| switch (err) {
        error.OutOfMemory => fatal("out of memory", .{}),
    };

    defer assets.deinit(gpa);

    const bind_args = .{ io, gpa, csprng, &assets, &addresses, concurrent_sessions_limit };

    var app_future = io.concurrent(app.bind, bind_args) catch |concurrent_err| switch (concurrent_err) {
        error.ConcurrencyUnavailable => {
            @call(.auto, app.bind, bind_args) catch |err| switch (err) {
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
    exit(1);
}

const is_debug = builtin.mode == .Debug;

const Io = std.Io;
const Init = std.process.Init;
const DefaultCsprng = std.Random.DefaultCsprng;

const heap = std.heap;
const net = std.Io.net;
const exit = std.process.exit;

const app = @import("app.zig");
const Assets = @import("Assets.zig");
const Server = @import("Server.zig");

const std = @import("std");
const rmio = @import("rmio");
const rmcli = @import("rmcli");
const builtin = @import("builtin");
