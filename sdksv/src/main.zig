const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Random = std.Random;
const process = std.process;
const assert = std.debug.assert;
const Threaded = std.Io.Threaded;
const Allocator = std.mem.Allocator;
const IpAddress = std.Io.net.IpAddress;
const DefaultCsprng = std.Random.DefaultCsprng;
const Base64Decoder = std.base64.standard.Decoder;

const remielle = @import("remielle");
const rsa = remielle.rsa;
const http = remielle.http;
const Evented = remielle.io.Evented;

const json = @import("json.zig");
const Account = @import("Account.zig");

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
    @"--concurrency": u32 = 16,
    @"--account-limit": u32 = 32,
    @"--storage-file": []const u8 = "storage/account.bin",
    @"--require-secure-random": bool = true,
};

fn usage(io: Io) noreturn {
    const defaults: Args = .{};

    Io.File.stdout().writeStreamingAll(io, std.fmt.comptimePrint(
        \\Usage: remielle-sdksv [options]
        \\
        \\Options:
        \\  --help, -h                Print this help and exit
        \\  --listen-address          TCP listen address; default is {q}
        \\  --concurrency             Limit of concurrent connections; default is {d}
        \\  --account-limit           Allowed number of accounts to register; default is {d}
        \\  --storage-file            On-disk account storage file path; default is {q}
        \\  --require-secure-random   Whether to abort on entropy unavailability; default is {any}
        \\
    , .{
        defaults.@"--listen-address",
        defaults.@"--concurrency",
        defaults.@"--account-limit",
        defaults.@"--storage-file",
        defaults.@"--require-secure-random",
    })) catch {};
    process.exit(0);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

const decrypt_fail_message = "Login failed. Your client patch might be unsupported.";
const name_too_long_message = "Username is too long";
const password_mismatch_message = "Account or password error";
const token_mismatch_message = "For account safety, please log in again.";

const Sdk = struct {
    csprng: Random,
    server: *http.Server,
    account_storage: *Account.Storage,
    account_storage_path: []const u8,
};

pub fn main(init: process.Init.Minimal) !void {
    const gpa = if (use_safe_allocator) safe_allocator.allocator() else std.heap.smp_allocator;
    defer if (use_safe_allocator) {
        _ = safe_allocator.deinit();
    };

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

    var csprng_seed: [DefaultCsprng.secret_seed_length]u8 = undefined;
    io.randomSecure(&csprng_seed) catch |err| switch (err) {
        error.Canceled => unreachable, // no
        error.EntropyUnavailable => if (args.@"--require-secure-random")
            fatal("secure entropy source is uavailable", .{})
        else
            io.random(&csprng_seed),
    };
    var csprng: DefaultCsprng = .init(csprng_seed);

    var account_storage = Account.Storage.initCapacity(
        arena,
        args.@"--account-limit",
    ) catch |err| switch (err) {
        error.OutOfMemory => fatal(
            \\failed to allocate in-memory account storage
            \\likely cause: --account-limit is higher than the system can process
        , .{}),
    };

    if (Io.Dir.path.dirname(args.@"--storage-file")) |dir_path|
        try Io.Dir.cwd().createDirPath(io, dir_path);

    loadAccountStorageFromFileIfExists(
        io,
        &account_storage,
        args.@"--storage-file",
    ) catch |err| switch (err) {
        error.StorageFileVersionMismatch => fatal(
            \\storage file version doesn't match
        , .{}),
        error.StorageFileOversize => fatal(
            \\storage file contents exceed --account-limit
            \\likely cause: storage file is produced by a server with higher limit
        , .{}),
        else => |e| return e,
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
        .rx_buf_len = 8192,
        .tx_buf_len = 8192,
    }) catch |err| switch (err) {
        error.ConcurrencyUnavailable, error.OutOfMemory => |e| fatal(
            \\failed to initialize http server ({t})
            \\likely cause: --concurrency is higher than the system can process
        , .{e}),
    };
    defer http_server.deinit(io, gpa);

    const sdk: Sdk = .{
        .csprng = csprng.random(),
        .server = &http_server,
        .account_storage = &account_storage,
        .account_storage_path = args.@"--storage-file",
    };

    var server_task = try io.concurrent(runServerTask, .{ io, &sdk, net_server.socket.address });
    defer server_task.cancel(io) catch {};

    switch (io_mode) {
        .evented => evented_instance.waitForShutdown(),
        .threaded => remielle.io.waitForShutdownThreaded(&threaded_instance),
    }
}

fn runServerTask(io: Io, sdk: *const Sdk, address: IpAddress) Io.Cancelable!void {
    remielle.splash.print();

    log.info("waiting for requests at {f}", .{address});
    defer log.info("shutting down...", .{});

    while (sdk.server.next(io)) |request| {
        defer request.finish(io);
        serve(io, sdk, request) catch |err| log.warn(
            "failed to serve request {q}: {t}",
            .{ request.data.line.target, err },
        );
    } else |err| switch (err) {
        error.Canceled => |e| return e,
    }
}

const mdk_shield_config_json =
    \\{"retcode":0,"message":"OK","data":{"id":31,"game_key":"nap_cn","client":"PC","identity":"I_IDENTITY","guest":false,"ignore_versions":"","scene":"S_NORMAL","name":"Nap","disable_regist":false,"enable_email_captcha":false,"thirdparty":[],"disable_mmt":false,"server_guest":false,"thirdparty_ignore":{},"enable_ps_bind_account":false,"thirdparty_login_configs":{},"initialize_firebase":false,"bbs_auth_login":false,"bbs_auth_login_ignore":[],"fetch_instance_id":false,"enable_flash_login":false,"enable_logo_18":false,"logo_height":"0","logo_width":"0","enable_cx_bind_account":false,"firebase_blacklist_devices_switch":false,"firebase_blacklist_devices_version":0,"hoyolab_auth_login":false,"hoyolab_auth_login_ignore":[],"hoyoplay_auth_login":true,"enable_douyin_flash_login":false,"enable_age_gate":false,"enable_age_gate_ignore":[]}}
;

fn serve(
    io: Io,
    sdk: *const Sdk,
    request: *http.Server.Request,
) !void {
    const Path = enum {
        @"/mdk/shield/api/loadConfig",
        @"/account/ma-passport/api/appLoginByPassword",
        @"/account/ma-passport/token/verifySToken",
        @"/combo/granter/login/v2/login",
    };

    const path_string, _ = request.data.line.splitTarget();

    const path_tag_maybe = std.meta.stringToEnum(Path, path_string) orelse strip_prefix: {
        // findScalarPos - starting with index `1`,
        // because at index `0` there's the leading separator.
        const next_component_index = mem.findScalarPos(u8, path_string, 1, '/') orelse
            break :strip_prefix null;

        break :strip_prefix std.meta.stringToEnum(Path, path_string[next_component_index..]);
    };

    const path_tag = path_tag_maybe orelse
        return request.respondString(.not_found, "404 Not Found");

    switch (path_tag) {
        .@"/mdk/shield/api/loadConfig" => {
            return request.respondString(.ok, mdk_shield_config_json);
        },
        .@"/combo/granter/login/v2/login" => {
            return serveComboGranterLoginV2(request);
        },
        .@"/account/ma-passport/api/appLoginByPassword" => {
            return serveLoginByPassword(io, sdk, request);
        },
        .@"/account/ma-passport/token/verifySToken" => {
            return serveVerifyToken(sdk, request);
        },
    }
}

fn serveComboGranterLoginV2(request: *http.Server.Request) !void {
    const LoginParam = struct {
        uid: []const u8,
        token: []const u8,
    };

    const param = json.view(LoginParam, .escaped_once, request.data.body) orelse
        return error.BadRequest;

    try request.respondPrint(
        .ok,
        \\{{"retcode":0,"message":"OK","data":{{"account_type":1,"combo_id":"{s}","combo_token":"{s}","data":"{{\"guest\":false}}","heartbeat":false,"open_id":"{s}"}}
    ,
        .{ param.uid, param.token, param.uid },
    );
}

fn serveLoginByPassword(
    io: Io,
    sdk: *const Sdk,
    request: *http.Server.Request,
) !void {
    const LoginByPasswordParam = struct {
        account: []const u8,
        password: []const u8,

        pub fn decrypt(
            param: *const @This(),
            account_plaintext_buf: *[rsa.block_size]u8,
            password_plaintext_buf: *[rsa.block_size]u8,
        ) !@This() {
            if ((try Base64Decoder.calcSizeForSlice(param.account)) != rsa.block_size)
                return error.BadCiphertextSize;

            if ((try Base64Decoder.calcSizeForSlice(param.password)) != rsa.block_size)
                return error.BadCiphertextSize;

            var account_ciphertext_buf: [rsa.block_size]u8 = undefined;
            var password_ciphertext_buf: [rsa.block_size]u8 = undefined;

            try Base64Decoder.decode(
                &account_ciphertext_buf,
                param.account,
            );

            try Base64Decoder.decode(
                &password_ciphertext_buf,
                param.password,
            );

            return .{
                .account = rsa.server_private_key.decrypt(
                    &account_ciphertext_buf,
                    account_plaintext_buf,
                ) orelse return error.DecryptFailed,
                .password = rsa.server_private_key.decrypt(
                    &password_ciphertext_buf,
                    password_plaintext_buf,
                ) orelse return error.DecryptFailed,
            };
        }
    };

    const encrypted_param = json.view(LoginByPasswordParam, .none, request.data.body) orelse
        return error.BadRequest;

    var account_buf: [rsa.block_size]u8 = undefined;
    var password_buf: [rsa.block_size]u8 = undefined;

    const param = encrypted_param.decrypt(&account_buf, &password_buf) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable, // comes from base64 error set, though it's not used there.

        error.InvalidPadding,
        error.InvalidCharacter,
        // Report as bad request, legitimate client wouldn't send an invalid base64.
        => return error.BadRequest,

        error.BadCiphertextSize,
        error.DecryptFailed,
        => return try respondError(request, decrypt_fail_message),
    };

    const username = Account.Username.fromSlice(param.account) orelse
        return try respondError(request, name_too_long_message);

    const account_new: Account = .{
        .username = username,
        .password = .init(sdk.csprng, param.password),
        .token = .random(sdk.csprng),
    };

    const result = sdk.account_storage.getOrInsertByUsername(
        account_new,
    ) catch |err| switch (err) {
        error.AccountStorageCapacityExceeded => {
            log.warn("account storage is full; aborting new account creation", .{});
            return try respondError(request, password_mismatch_message);
        },
    };

    const account: Account = account: {
        if (!result.found) {
            // New account has been created, save it.
            try saveAccountStorage(io, sdk);
            break :account account_new;
        } else {
            // Verify password of existing account.
            const account_old = sdk.account_storage.list.get(@backingInt(result.index));
            if (account_old.password.verify(param.password))
                break :account account_old;

            return try respondError(request, password_mismatch_message);
        }
    };

    try respondPassportApiLoginSuccess(
        request,
        result.index,
        &account,
    );
}

fn serveVerifyToken(
    sdk: *const Sdk,
    request: *http.Server.Request,
) !void {
    const VerifyTokenParam = struct {
        mid: []const u8,
        stoken: []const u8,
    };
    const param = json.view(VerifyTokenParam, .none, request.data.body) orelse
        return error.BadRequest;

    const id_int = std.fmt.parseInt(u32, param.mid, 10) catch
        return try request.respondString(.bad_request, "400 Bad Request");

    const account_index = Account.Index.fromUid(id_int) orelse
        return try request.respondString(.bad_request, "400 Bad Request");

    const account = sdk.account_storage.getByIndex(account_index) orelse
        return try respondError(request, token_mismatch_message);

    if (!account.token.eql(param.stoken))
        return try respondError(request, token_mismatch_message);

    try respondPassportApiLoginSuccess(
        request,
        account_index,
        &account,
    );
}

fn respondPassportApiLoginSuccess(
    request: *http.Server.Request,
    account_index: Account.Index,
    account: *const Account,
) !void {
    var id_buf: ["-2147483648".len]u8 = undefined;
    const id = mem.print(&id_buf, "{d}", .{account_index.toUid()}) catch unreachable;

    const response = .{
        .retcode = 0,
        .message = "OK",
        .data = .{
            .token = .{ .token_type = 1, .token = &account.token.chars },
            .user_info = .{
                .aid = id,
                .mid = id,
                .account_name = "",
                .email = account.username.toSlice(),
                .is_email_verify = 0,
                .area_code = "**",
                .mobile = "",
                .safe_area_code = "",
                .safe_mobile = "",
                .realname = "",
                .identity_code = "",
                .rebind_area_code = "",
                .rebind_mobile = "",
                .rebind_mobile_time = "228",
                .links = @as([]const u32, &.{}),
                .country = "RU",
                .password_time = "1337",
                .is_adult = 0,
                .unmasked_email = "",
                .unmasked_email_type = 0,
            },
            .ext_user_info = .{
                .guardian_email = "",
                .birth = "0",
            },
            .reactivate_action_ticket = "",
            .bind_email_action_ticket = "",
        },
    };

    try request.respondPrint(.ok, "{f}", .{std.json.fmt(response, .{})});
}

fn respondError(request: *http.Server.Request, comptime msg: []const u8) !void {
    try request.respondString(.ok,
        \\{"retcode":-101,"message":"
    ++ msg ++
        \\","data":null}
    );
}

fn loadAccountStorageFromFileIfExists(
    io: Io,
    storage: *Account.Storage,
    sub_path: []const u8,
) !void {
    const file = Io.Dir.cwd().openFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer file.close(io);

    // with vectored read this buffer might be not useful,
    // but some operating systems may not support
    // vectored I/O, for these it is possible
    // to lower the amount of syscalls
    // by saving data to this extra buffer especially for small files.
    var file_reader_buffer: [1024]u8 = undefined;
    var file_reader = file.readerStreaming(io, &file_reader_buffer);

    const header = file_reader.interface.takeStruct(
        Account.Storage.Header,
        .little,
    ) catch |err| switch (err) {
        error.EndOfStream => |e| return e,
        error.ReadFailed => return file_reader.err.?,
    };

    if (header.version != Account.Storage.Header.current_version)
        return error.StorageFileVersionMismatch;

    if (header.item_count > storage.list.capacity)
        return error.StorageFileOversize;

    assert(storage.list.len == 0);
    storage.list.len = header.item_count;

    var vector = storage.writableVector();
    file_reader.interface.readVecAll(&vector) catch |err| switch (err) {
        error.EndOfStream => |e| return e,
        error.ReadFailed => return file_reader.err.?,
    };

    storage.reIndexAssumeFirstIndexing();
}

fn saveAccountStorage(io: Io, sdk: *const Sdk) !void {
    const file = try Io.Dir.cwd().createFile(io, sdk.account_storage_path, .{});
    defer file.close(io);

    var file_writer_buffer: [1024]u8 = undefined;
    var file_writer = file.writerStreaming(io, &file_writer_buffer);

    const header: Account.Storage.Header = .{
        .version = Account.Storage.Header.current_version,
        .item_count = @intCast(sdk.account_storage.count()),
    };
    file_writer.interface.writeAll(@ptrCast(&header)) catch return file_writer.err.?;

    var vector = sdk.account_storage.readableVector();
    file_writer.interface.writeVecAll(&vector) catch return file_writer.err.?;
    file_writer.interface.flush() catch return file_writer.err.?;
}
