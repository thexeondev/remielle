const builtin = @import("builtin");
const is_debug = builtin.mode == .debug;

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const net = std.Io.net;
const process = std.process;
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const Threaded = std.Io.Threaded;
const Allocator = std.mem.Allocator;
const DefaultCsprng = std.Random.DefaultCsprng;

const remielle = @import("remielle");
const assets = remielle.assets;
const protocol = remielle.protocol;
const protobuf = remielle.protobuf;
const Evented = remielle.io.Evented;

const logic = @import("logic.zig");
const messaging = @import("messaging.zig");
const Persistent = @import("Persistent.zig");

const initial_xorpad: *const [4096]u8 = @embedFile("initial_xorpad");

const log = std.log.scoped(.@"remielle-gamesv");

pub const Args = struct {
    @"--listen-address": []const u8 = "127.0.0.1:20501",
    @"--concurrency": u32 = 16,
    @"--require-secure-random": bool = true,
};

pub const std_options: std.Options = .{
    .logFn = remielle.log.logFn,
};

var evented_instance: Evented = undefined;
var threaded_instance: Threaded = undefined;

const io_mode: remielle.io.Mode = .configured;

fn usage(io: Io) noreturn {
    const defaults: Args = .{};

    Io.File.stdout().writeStreamingAll(io, std.fmt.comptimePrint(
        \\Usage: remielle-gamesv [options]
        \\
        \\Options:
        \\  --help, -h                Print this help and exit
        \\  --listen-address          TCP listen address; default is {q}
        \\  --concurrency             Limit of concurrent connections; default is {d}
        \\  --require-secure-random   Whether to abort on entropy unavailability; default is {any}
        \\
    , .{
        defaults.@"--listen-address",
        defaults.@"--concurrency",
        defaults.@"--require-secure-random",
    })) catch {};
    process.exit(0);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    process.exit(1);
}

pub fn main(init: process.Init.Minimal) !void {
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

    const io = switch (io_mode) {
        .evented => evented: {
            evented_instance = try .init(gpa, .{
                .coroutine_limit = .unlimited,
                .stack_size = 1024 * 1024,
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

    const address = net.IpAddress.parseLiteral(args.@"--listen-address") catch |err|
        fatal("bad --listen-address: {t}", .{err});

    var csprng_seed: [DefaultCsprng.secret_seed_length]u8 = undefined;
    io.randomSecure(&csprng_seed) catch |err| switch (err) {
        error.Canceled => unreachable,
        error.EntropyUnavailable => if (args.@"--require-secure-random")
            fatal("secure entropy source is uavailable", .{})
        else
            io.random(&csprng_seed),
    };

    var csprng: DefaultCsprng = .init(csprng_seed);

    var asset_lookup = assets.Lookup.init(gpa) catch |err| switch (err) {
        error.OutOfMemory => fatal("out of memory", .{}),
    };
    defer asset_lookup.deinit(gpa);

    var net_server = address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 64,
    }) catch |err| switch (err) {
        error.AddressInUse => fatal(
            \\address {qf} is already in use
            \\likely cause: another instance of this server is already running
        , .{address}),
        else => |e| fatal("failed to start: {t}", .{e}),
    };
    defer net_server.deinit(io);

    var session_index_by_uid: std.array_hash_map.Auto(u32, u32) = .empty;
    defer session_index_by_uid.deinit(gpa);
    session_index_by_uid.ensureTotalCapacity(gpa, args.@"--concurrency") catch
        fatal(
            \\failed to allocate memory for {d} sessions
            \\likely cause: --concurrency is higher than the system can process
        , .{args.@"--concurrency"});

    const player_uids = gpa.alloc(u32, args.@"--concurrency") catch
        fatal(
            \\failed to allocate memory for {d} sessions
            \\likely cause: --concurrency is higher than the system can process
        , .{args.@"--concurrency"});
    defer gpa.free(player_uids);
    @memset(player_uids, 0);

    const sessions = gpa.alloc(Session, args.@"--concurrency") catch
        fatal(
            \\failed to allocate memory for {d} sessions
            \\likely cause: --concurrency is higher than the system can process
        , .{args.@"--concurrency"});
    defer gpa.free(sessions);

    const connections = gpa.alloc(Connection, args.@"--concurrency") catch
        fatal(
            \\failed to allocate memory for {d} sessions
            \\likely cause: --concurrency is higher than the system can process
        , .{args.@"--concurrency"});
    defer gpa.free(connections);

    var persistent = Persistent.init(io, gpa, .cwd()) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| fatal("failed to initialize Persistent: {t}", .{e}),
    };

    defer persistent.deinit(gpa);

    var event_queue: Io.Queue(Connection.Event) = .init(&.{});

    const game: Game = .{
        .csprng = csprng.random(),
        .asset_lookup = &asset_lookup,
        .session_index_by_uid = &session_index_by_uid,
        .player_uids = player_uids,
        .sessions = sessions,
        .connections = connections,
        .event_queue = &event_queue,
        .persistent = &persistent,
    };

    var connection_group: Io.Group = .init;
    defer connection_group.cancel(io);

    for (game.connections, 0..) |*connection, index| {
        connection.initPinned(@intCast(index));
        connection_group.concurrent(
            io,
            runConnectionTask,
            .{ io, connection, &net_server, &event_queue },
        ) catch
            fatal(
                \\failed to allocate concurrency for {d} sessions
                \\likely cause: --concurrency is higher than the system can process
            , .{args.@"--concurrency"});
    }

    var server_task = try io.concurrent(runServerTask, .{ io, gpa, &game });
    defer server_task.cancel(io) catch {};

    switch (io_mode) {
        .evented => evented_instance.waitForShutdown(),
        .threaded => remielle.io.waitForShutdownThreaded(&threaded_instance),
    }
}

const Game = struct {
    csprng: std.Random,
    asset_lookup: *const assets.Lookup,
    session_index_by_uid: *std.array_hash_map.Auto(u32, u32),
    player_uids: []u32,
    sessions: []Session,
    connections: []Connection,
    event_queue: *Io.Queue(Connection.Event),
    persistent: *Persistent,
};

const Session = struct {
    packet_id_counter: u32,
    xorpad: [4096]u8,
    properties: logic.Properties,
};

fn runServerTask(io: Io, gpa: Allocator, game: *const Game) Io.Cancelable!void {
    try remielle.splash.print(io);
    var send_buffer: [32 * 1024]u8 = undefined;
    _ = &send_buffer;

    while (game.event_queue.getOne(io)) |event| {
        switch (event) {
            .disconnected => |disconnected| {
                const uid = game.player_uids[disconnected.index];
                if (uid == 0) continue;

                assert(game.session_index_by_uid.swapRemove(uid));
                game.player_uids[disconnected.index] = 0;
            },
            .readable => |readable| {
                defer readable.done.set(io);

                var sink: Io.Writer = .fixed(&send_buffer);
                const time: Io.Timestamp = .now(io, .real);
                const session = &game.sessions[readable.index];
                const connection = &game.connections[readable.index];

                for (readable.commands) |*command| {
                    const uid = game.player_uids[readable.index];
                    if (uid == 0) {
                        processFirstCommand(
                            io,
                            gpa,
                            game,
                            readable.index,
                            command,
                            &sink,
                        ) catch |err| switch (err) {
                            error.Canceled => |e| return e,
                            else => |e| {
                                log.err("failed to process first command: {t}", .{e});
                                connection.should_close = true;
                            },
                        };
                    } else {
                        protocol.xor(command.body, &session.xorpad);

                        var arena: std.heap.ArenaAllocator = .init(gpa);
                        defer arena.deinit();

                        messaging.handlers.process(
                            arena.allocator(),
                            time,
                            &.{
                                .packet_id_counter = &session.packet_id_counter,
                                .xorpad = &session.xorpad,
                                .writer = &sink,
                            },
                            &session.properties,
                            game.asset_lookup,
                            &game.persistent.calendar,
                            command,
                        ) catch |err|
                            log.debug("process failed: {t}", .{err});
                    }
                }

                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();

                const uid = game.player_uids[readable.index];
                if (uid != 0) {
                    const player_save = logic.Properties.toPlayerSave(
                        &session.properties,
                        arena.allocator(),
                    ) catch |err| switch (err) {
                        error.OutOfMemory => {
                            // TODO: get rid of protobuf for saves to avoid this error.
                            log.err("ran out of memory while constructing save for UID {d}", .{uid});
                            return;
                        },
                    };

                    const old_cancel_protection = io.swapCancelProtection(.blocked);
                    defer _ = io.swapCancelProtection(old_cancel_protection);

                    game.persistent.savePlayer(io, uid, player_save) catch |err| switch (err) {
                        error.Canceled => unreachable, // blocked
                        else => |e| log.err("failed to save player with UID {d}: {t}", .{ uid, e }),
                    };
                }

                const written = sink.buffered();
                if (written.len != 0)
                    try game.connections[readable.index].writeAll(io, written);
            },
        }
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        error.Closed => unreachable,
    }
}

fn processFirstCommand(
    io: Io,
    gpa: Allocator,
    game: *const Game,
    session_index: u32,
    command: *const protocol.Command,
    sink: *Io.Writer,
) !void {
    // TODO: eliminate heap allocations (blocked by Persistent rewrite)

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    if (command.id != protobuf.main_desc.PlayerGetTokenCsReq.cmd_id)
        return error.UnexpectedFirstCmdId;

    protocol.xor(command.body, initial_xorpad);

    var string_buffer: [1024]u8 = undefined;

    var br: Io.Reader = .fixed(command.body);
    var fba: std.heap.FixedBufferAllocator = .init(&string_buffer);

    const request = protobuf.decode(
        .main,
        protobuf.main.PlayerGetTokenCsReq,
        fba.allocator(),
        &br,
    ) catch
        return error.MalformedPayload;

    const client_rand_key = remielle.rsa.decryptString(@constCast(request.client_rand_key)) catch
        return error.DecryptFail;

    if (client_rand_key.len != 8)
        return error.DecryptFail;

    const get_or_create = try game.persistent.getOrCreatePlayerUid(io, request.account_uid, gpa);
    game.sessions[session_index].packet_id_counter = 0;
    game.sessions[session_index].properties = .init;

    if (get_or_create.created) {
        game.sessions[session_index].properties.setDefaults();
    } else blk: {
        // TODO: less retarded way of loading this.

        if (game.persistent.loadPlayer(io, arena, get_or_create.player_uid)) |player_save| {
            if (game.sessions[session_index].properties.fromPlayerSave(&player_save))
                break :blk
            else |_| {}
        } else |_| {}

        game.sessions[session_index].properties.setDefaults();
    }

    const server_rand_key = game.csprng.int(u64);
    var encrypt_buffer: remielle.rsa.EncryptAndSignBuffer = undefined;
    remielle.rsa.encryptAndSign(&encrypt_buffer, @ptrCast(&server_rand_key));

    const response: protobuf.main.PlayerGetTokenScRsp = .{
        .uid = get_or_create.player_uid,
        .server_rand_key = &encrypt_buffer.ciphertext,
        .sign = &encrypt_buffer.sign,
    };

    try protocol.Command.encode(
        sink,
        protobuf.main_desc.PlayerGetTokenScRsp.cmd_id,
        .{},
        response,
        initial_xorpad,
    );

    protocol.getDecryptVector(
        &game.sessions[session_index].xorpad,
        mem.readInt(u64, client_rand_key[0..8], .little) ^ server_rand_key,
    );

    game.player_uids[session_index] = get_or_create.player_uid;
    game.session_index_by_uid.putAssumeCapacity(get_or_create.player_uid, session_index);
}

const Connection = struct {
    const command_batch_size = 32;

    index: u32,

    /// Used only to protect against accidental closure.
    /// Contention is unlikely, so this is fine.
    stream_mutex: Io.Mutex,
    stream_maybe: ?Io.net.Stream,

    read_buffer: [32 * 1024]u8,
    read_done: Io.Event,
    should_close: bool,

    const Event = union(enum) {
        readable: struct {
            index: u32,
            commands: []protocol.Command,
            done: *Io.Event,
        },
        disconnected: struct {
            index: usize,
        },
    };

    fn initPinned(connection: *Connection, index: u32) void {
        connection.index = index;
        connection.stream_mutex = .init;
        connection.stream_maybe = null;
        connection.read_done = .unset;
        connection.should_close = false;
    }

    fn writeAll(connection: *Connection, io: Io, buffer: []const u8) Io.Cancelable!void {
        try connection.stream_mutex.lock(io);
        defer connection.stream_mutex.unlock(io);

        const stream = connection.stream_maybe orelse return;
        var remaining = buffer;

        while (remaining.len != 0) {
            var vector: [1][]const u8 = .{remaining};

            const result = try io.operate(.{ .net_write = .{
                .socket_handle = stream.socket.handle,
                .data = &vector,
            } });

            const written = result.net_write catch return;
            remaining = remaining[written..];
        }
    }
};

fn runConnectionTask(
    io: Io,
    context: *Connection,
    server: *Io.net.Server,
    queue: *Io.Queue(Connection.Event),
) Io.Cancelable!void {
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => continue,
        };

        try context.stream_mutex.lock(io);
        assert(context.stream_maybe == null);
        context.stream_maybe = stream;
        context.stream_mutex.unlock(io);

        receiveMessages(io, context, &stream, queue) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.ConnectionResetByPeer => {},
            else => |e| log.debug(
                "failed to read messages from {f}: {t}",
                .{ stream.socket.address, e },
            ),
        };

        queue.putOne(
            io,
            .{ .disconnected = .{ .index = context.index } },
        ) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.Closed => unreachable,
        };

        try context.stream_mutex.lock(io);
        context.stream_maybe.?.close(io);
        context.stream_maybe = null;
        context.stream_mutex.unlock(io);
    }
}

fn receiveMessages(
    io: Io,
    context: *Connection,
    stream: *const net.Stream,
    queue: *Io.Queue(Connection.Event),
) !void {
    var read_buffer_end: usize = 0;
    context.should_close = false;

    while (true) {
        var vector: [1][]u8 = .{context.read_buffer[read_buffer_end..]};
        const result = try io.operate(.{ .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &vector,
        } });

        const read_n = try result.net_read;
        if (read_n == 0) return error.EndOfStream;

        read_buffer_end += read_n;
        const readable = context.read_buffer[0..read_buffer_end];

        var batch_buffer: [Connection.command_batch_size]protocol.Command = undefined;
        var batch: ArrayList(protocol.Command) = .initBuffer(&batch_buffer);

        var consumed_n: usize = 0;
        defer {
            const new_end = read_buffer_end - consumed_n;
            @memmove(
                context.read_buffer[0..new_end],
                context.read_buffer[consumed_n..read_buffer_end],
            );

            read_buffer_end = new_end;
        }

        while (try protocol.Command.decode(readable[consumed_n..])) |decoded| {
            consumed_n += decoded.consumed_bytes;

            batch.appendBounded(decoded.command) catch {
                context.read_done = .unset;

                queue.putOne(io, .{ .readable = .{
                    .index = context.index,
                    .commands = batch.items,
                    .done = &context.read_done,
                } }) catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    error.Closed => unreachable,
                };

                try context.read_done.wait(io);

                if (context.should_close)
                    return;

                batch.items.len = 0;
                batch.appendAssumeCapacity(decoded.command);
            };
        }

        if (batch.items.len != 0) {
            context.read_done = .unset;

            queue.putOne(io, .{ .readable = .{
                .index = context.index,
                .commands = batch.items,
                .done = &context.read_done,
            } }) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => unreachable,
            };

            try context.read_done.wait(io);

            if (context.should_close)
                return;
        }
    }
}
