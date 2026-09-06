const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const process = std.process;

const remielle = @import("remielle");

const app = @import("app.zig");
const Data = @import("Data.zig");

const log = std.log.scoped(.@"remielle-dpsv");

pub const Args = struct {
    @"--listen-address": []const u8 = @import("config").listen_address,
};

pub const std_options: std.Options = .{
    .logFn = remielle.log.logFn,
};

pub fn usage(io: Io) noreturn {
    const defaults: Args = .{};

    Io.File.stdout().writeStreamingAll(io, std.fmt.comptimePrint(
        \\Usage: remielle-dpsv [options]
        \\
        \\Options:
        \\  --help, -h        Print this help and exit
        \\  --listen-address  TCP listen address; default is {q}
        \\
    , .{defaults.@"--listen-address"})) catch {};
    process.exit(0);
}

pub fn main(init: process.Init.Minimal) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

    const args_slice = init.args.toSlice(arena.allocator()) catch |err|
        fatal("failed to collect cli arguments: {t}", .{err});

    var io_impl = if (remielle.io.RemiellIo.supported)
        remielle.io.RemiellIo.init(std.heap.page_allocator, .{
            .coroutine_limit = .unlimited, // TODO
            .stack_size = 1024 * 128,
        }) catch |err|
            fatal("failed to init I/O implementation: {t}", .{err})
    else
        Io.Threaded.init(std.heap.page_allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
    defer io_impl.deinit();
    const io = io_impl.io();

    const args = remielle.args.parse(Args, log, args_slice) orelse usage(io);

    const listen_address = net.IpAddress.parseLiteral(args.@"--listen-address") catch |err|
        fatal("bad listen address specified: {t}", .{err});

    const data = Data.build(arena.allocator()) catch |err| switch (err) {
        error.OutOfMemory => fatal("failed to build static responses", .{}),
    };

    remielle.splash.print();

    const listen_args = .{ io, &data, &listen_address };

    var app_future = io.concurrent(app.listen, listen_args) catch |err|
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
    std.process.exit(1);
}
