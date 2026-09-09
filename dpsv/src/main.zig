const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const process = std.process;
const Threaded = std.Io.Threaded;
const IpAddress = std.Io.net.IpAddress;

const remielle = @import("remielle");
const http = remielle.http;
const Evented = remielle.io.Evented;
const StaticAllocator = remielle.StaticAllocator;

const Data = @import("Data.zig");

const log = std.log.scoped(.@"remielle-dpsv");

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

pub const Args = struct {
    @"--listen-address": []const u8 = @import("config").listen_address,
    @"--concurrency": u32 = 16,
};

pub fn usage(io: Io) noreturn {
    const defaults: Args = .{};

    Io.File.stdout().writeStreamingAll(io, std.fmt.comptimePrint(
        \\Usage: remielle-dpsv [options]
        \\
        \\Options:
        \\  --help, -h        Print this help and exit
        \\  --listen-address  TCP listen address; default is {q}
        \\  --concurrency     Limit of concurrent connections; default is {d}
        \\
    , .{
        defaults.@"--listen-address",
        defaults.@"--concurrency",
    })) catch {};
    process.exit(0);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

pub fn main(init: process.Init.Minimal) !void {
    const backing_gpa = if (use_safe_allocator) safe_allocator.allocator() else std.heap.smp_allocator;
    defer if (use_safe_allocator) {
        _ = safe_allocator.deinit();
    };

    var static_allocator: StaticAllocator = .init(backing_gpa);
    const gpa = static_allocator.allocator();

    const io = switch (io_mode) {
        .evented => evented: {
            evented_instance = try .init(gpa, .{
                .coroutine_limit = .unlimited,
                .stack_size = 1024 * 128,
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

    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args_slice = try init.args.toSlice(arena);
    const args = remielle.args.parse(Args, log, args_slice) orelse usage(io);

    if (args.@"--concurrency" == 0)
        fatal("--concurrency may not be zero", .{});

    const listen_address = IpAddress.parseLiteral(args.@"--listen-address") catch |err|
        fatal("bad listen address specified: {t}", .{err});

    const listen_options: IpAddress.ListenOptions = .{
        .reuse_address = true,
        .kernel_backlog = 64,
    };

    const data = Data.build(arena) catch |err| switch (err) {
        error.OutOfMemory => fatal("failed to build static responses", .{}),
    };

    var net_server = listen_address.listen(io, listen_options) catch |err| switch (err) {
        error.AddressInUse => fatal(
            \\address {qf} is already in use
            \\likely cause: another instance of this server is already running
        , .{listen_address}),
        else => |e| fatal("failed to start: {t}", .{e}),
    };
    defer net_server.deinit(io);

    var http_server = http.Server.init(io, gpa, &net_server, .{
        .task_count = args.@"--concurrency",
        .rx_buf_len = 4096,
        .tx_buf_len = 16384,
    }) catch |err| switch (err) {
        error.ConcurrencyUnavailable, error.OutOfMemory => |e| fatal(
            \\failed to initialize http server ({t})
            \\likely cause: --concurrency is higher than the system can process
        , .{e}),
    };
    defer http_server.deinit(io, gpa);

    var server_task = try io.concurrent(
        runServerTask,
        .{ io, &listen_address, &data, &http_server },
    );
    defer server_task.cancel(io) catch {};

    static_allocator.setBehavior(.@"unreachable");
    defer static_allocator.setBehavior(.allow_dealloc);

    switch (io_mode) {
        .evented => evented_instance.waitForShutdown(),
        .threaded => remielle.io.waitForShutdownThreaded(&threaded_instance),
    }
}

fn runServerTask(
    io: Io,
    address: *const IpAddress,
    data: *const Data,
    server: *http.Server,
) Io.Cancelable!void {
    remielle.splash.print(io);

    log.info("waiting for requests at {f}", .{address});
    defer log.info("shutting down...", .{});

    while (server.next(io)) |request| {
        defer request.finish(io);
        serve(data, request) catch |err| log.warn(
            "failed to serve request {q}: {t}",
            .{ request.data.line.target, err },
        );
    } else |err| switch (err) {
        error.Canceled => |e| return e,
    }
}

const fallback_response =
    \\{"retcode":70}
;

fn serve(data: *const Data, request: *http.Server.Request) !void {
    const DispatchQuery = struct {
        version: []const u8,
    };

    const GatewayQuery = struct {
        version: []const u8,
    };

    const path, const query_string = request.data.line.splitTarget();

    if (mem.eql(u8, path, "/query_dispatch")) {
        const query = http.Request.parseQuery(DispatchQuery, query_string) orelse
            return request.respondString(.bad_request, "400 Bad Request");

        return request.respondString(.ok, data.region_list_map.get(query.version) orelse
            unsupported: {
                log.warn("unsupported version: {s}", .{query.version});
                break :unsupported fallback_response;
            });
    } else if (mem.cutPrefix(u8, path, "/query_gateway/")) |server_name| {
        const server_tag = std.meta.stringToEnum(Data.Server, server_name) orelse
            return request.respondString(.not_found, "404 Not Found");

        const query = http.Request.parseQuery(GatewayQuery, query_string) orelse
            return request.respondString(.bad_request, "400 Bad Request");

        const version = std.meta.stringToEnum(Data.Version, query.version) orelse
            return request.respondString(.ok, fallback_response);

        return request.respondString(.ok, data.gateway_map.get(.{
            .version = version,
            .server = server_tag,
        }) orelse
            fallback_response);
    } else {
        return request.respondString(.not_found, "404 Not Found");
    }
}
