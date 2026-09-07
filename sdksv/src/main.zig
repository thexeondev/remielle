const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const process = std.process;
const Threaded = std.Io.Threaded;
const Allocator = std.mem.Allocator;
const IpAddress = std.Io.net.IpAddress;
const Base64Decoder = std.base64.standard.Decoder;

const remielle = @import("remielle");
const rsa = remielle.rsa;
const http = remielle.http;
const Evented = remielle.io.Evented;

const json = @import("json.zig");
const Passwd = @import("Passwd.zig");

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
};

fn usage(io: Io) noreturn {
    const defaults: Args = .{};

    Io.File.stdout().writeStreamingAll(io, std.fmt.comptimePrint(
        \\Usage: remielle-sdksv [options]
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

const decrypt_fail_message = "Login failed. Your client patch might be unsupported.";
const name_too_long_message = "Username is too long";
const password_mismatch_message = "Account or password error";
const token_mismatch_message = "For account safety, please log in again.";

pub fn main(init: process.Init.Minimal) !void {
    const gpa = if (use_safe_allocator) safe_allocator.allocator() else std.heap.smp_allocator;
    defer if (use_safe_allocator) {
        _ = safe_allocator.deinit();
    };

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

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

    const listen_address = IpAddress.parseLiteral(args.@"--listen-address") catch |err|
        fatal("bad listen address specified: {t}", .{err});

    const listen_options: IpAddress.ListenOptions = .{
        .reuse_address = true,
        .kernel_backlog = 64,
    };

    var passwd = Passwd.load(io, gpa, .cwd()) catch |err|
        fatal("failed to load passwd file: {t}", .{err});
    defer passwd.deinit(gpa);

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
        .rx_buf_len = 16384,
        .tx_buf_len = 16384,
    }) catch |err| switch (err) {
        error.ConcurrencyUnavailable, error.OutOfMemory => |e| fatal(
            \\failed to initialize http server ({t})
            \\likely cause: --concurrency is higher than the system can process
        , .{e}),
    };
    defer http_server.deinit(io, gpa);

    remielle.splash.print();

    var server_task = try io.concurrent(runServerTask, .{ io, gpa, &http_server, &passwd });
    defer server_task.cancel(io) catch {};

    switch (io_mode) {
        .evented => evented_instance.waitForShutdown(),
        .threaded => remielle.io.waitForShutdownThreaded(&threaded_instance),
    }
}

fn runServerTask(
    io: Io,
    gpa: Allocator,
    server: *http.Server,
    passwd: *Passwd,
) Io.Cancelable!void {
    while (server.next(io)) |request| {
        defer request.finish(io);
        serve(io, gpa, request, passwd) catch |err| log.warn(
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
    gpa: Allocator,
    request: *http.Server.Request,
    passwd: *Passwd,
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
            return serveLoginByPassword(io, gpa, request, passwd);
        },
        .@"/account/ma-passport/token/verifySToken" => {
            return serveVerifyToken(request, passwd);
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
    gpa: Allocator,
    request: *http.Server.Request,
    passwd: *Passwd,
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

    const name = Passwd.Name.fromSlice(param.account) catch |err| switch (err) {
        error.TooLongString => return try respondError(request, name_too_long_message),
    };

    const id = passwd.loginByPassword(name, param.password) catch |login_err| {
        switch (login_err) {
            error.UsernameNotExist => {
                const old_cancel_protection = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(old_cancel_protection);

                const id = passwd.create(
                    io,
                    gpa,
                    name,
                    param.password,
                ) catch |err| {
                    switch (err) {
                        error.Canceled => unreachable, // blocked
                        else => return error.Internal,
                    }
                };

                passwd.save(io, .cwd()) catch |err| switch (err) {
                    error.Canceled => unreachable, // blocked
                    else => return error.Internal,
                };

                var id_buf: [Passwd.Id.fmt_len]u8 = undefined;

                return try respondPassportApiLoginSuccess(
                    request,
                    id.toString(&id_buf),
                    param.account,
                    &passwd.getToken(id).?.string,
                );
            },
            error.PasswordMismatch => return try respondError(
                request,
                password_mismatch_message,
            ),
        }
    };

    var id_buf: [Passwd.Id.fmt_len]u8 = undefined;
    try respondPassportApiLoginSuccess(
        request,
        id.toString(&id_buf),
        param.account,
        &passwd.getToken(id).?.string,
    );
}

fn serveVerifyToken(
    request: *http.Server.Request,
    passwd: *Passwd,
) !void {
    const VerifyTokenParam = struct {
        mid: []const u8,
        stoken: []const u8,
    };
    const param = json.view(VerifyTokenParam, .none, request.data.body) orelse
        return error.BadRequest;

    const id = Passwd.Id.fromSlice(param.mid) orelse
        return error.BadRequest;

    const token = passwd.getToken(id) orelse
        return try respondError(request, token_mismatch_message);

    if (!token.eql(param.stoken))
        return try respondError(request, token_mismatch_message);

    const name = passwd.getName(id).?;
    var id_buf: [Passwd.Id.fmt_len]u8 = undefined;

    try respondPassportApiLoginSuccess(
        request,
        id.toString(&id_buf),
        name.string.view(),
        &token.string,
    );
}

fn respondPassportApiLoginSuccess(
    request: *http.Server.Request,
    id: []const u8,
    account: []const u8,
    token: []const u8,
) !void {
    const response = .{
        .retcode = 0,
        .message = "OK",
        .data = .{
            .token = .{ .token_type = 1, .token = token },
            .user_info = .{
                .aid = id,
                .mid = id,
                .account_name = "",
                .email = account,
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
