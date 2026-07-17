const std = @import("std");
const Base64Decoder = std.base64.standard.Decoder;

const remielle = @import("remielle");
const rsa = remielle.rsa;

const json = @import("../json.zig");
const routes = @import("../routes.zig");
const Passwd = @import("../Passwd.zig");

const decrypt_fail_message = "Login failed. Your client patch might be unsupported.";
const name_too_long_message = "Username is too long";
const password_mismatch_message = "Account or password error";
const token_mismatch_message = "For account safety, please log in again.";

const LoginByPasswordParam = struct {
    account: []const u8,
    password: []const u8,

    pub fn decrypt(
        param: *const LoginByPasswordParam,
        account_plaintext_buf: *[rsa.block_size]u8,
        password_plaintext_buf: *[rsa.block_size]u8,
    ) !LoginByPasswordParam {
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

const VerifyTokenParam = struct {
    mid: []const u8,
    stoken: []const u8,
};

pub fn @"/account/ma-passport/api/appLoginByPassword"(
    request: *const routes.Request,
) !void {
    const encrypted_param = json.view(LoginByPasswordParam, .none, request.payload.body) orelse
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
        => return try respondError(request.response, decrypt_fail_message),
    };

    const name = Passwd.Name.fromSlice(param.account) catch |err| switch (err) {
        error.TooLongString => return try respondError(request.response, name_too_long_message),
    };

    try request.passwd.sync.lockShared(request.io);

    const id = request.passwd.loginByPassword(name, param.password) catch |login_err| {
        request.passwd.sync.unlockShared(request.io);

        switch (login_err) {
            error.UsernameNotExist => {
                try request.passwd.sync.lock(request.io);
                defer request.passwd.sync.unlock(request.io);

                const old_cancel_protection = request.io.swapCancelProtection(.blocked);
                defer _ = request.io.swapCancelProtection(old_cancel_protection);

                const id = request.passwd.create(
                    request.io,
                    request.gpa,
                    name,
                    param.password,
                ) catch |err| {
                    switch (err) {
                        error.Canceled => unreachable, // blocked
                        else => return error.Internal,
                    }
                };

                request.passwd.save(request.io, .cwd()) catch |err| switch (err) {
                    error.Canceled => unreachable, // blocked
                    else => return error.Internal,
                };

                var id_buf: [Passwd.Id.fmt_len]u8 = undefined;

                return try respondSuccess(
                    request.response,
                    id.toString(&id_buf),
                    param.account,
                    &request.passwd.getToken(id).?.string,
                );
            },
            error.PasswordMismatch => return try respondError(
                request.response,
                password_mismatch_message,
            ),
        }
    };

    defer request.passwd.sync.unlockShared(request.io);

    var id_buf: [Passwd.Id.fmt_len]u8 = undefined;
    try respondSuccess(
        request.response,
        id.toString(&id_buf),
        param.account,
        &request.passwd.getToken(id).?.string,
    );
}

pub fn @"/account/ma-passport/token/verifySToken"(
    request: *const routes.Request,
) !void {
    const param = json.view(VerifyTokenParam, .none, request.payload.body) orelse
        return error.BadRequest;

    const id = Passwd.Id.fromSlice(param.mid) orelse
        return error.BadRequest;

    try request.passwd.sync.lockShared(request.io);
    defer request.passwd.sync.unlockShared(request.io);

    const token = request.passwd.getToken(id) orelse
        return try respondError(request.response, token_mismatch_message);

    if (!token.eql(param.stoken))
        return try respondError(request.response, token_mismatch_message);

    const name = request.passwd.getName(id).?;
    var id_buf: [Passwd.Id.fmt_len]u8 = undefined;

    try respondSuccess(request.response, id.toString(&id_buf), name.string.view(), &token.string);
}

fn respondError(r: *routes.ConcatStream, comptime msg: []const u8) !void {
    try r.appendConstant(
        \\{"retcode":-101,"message":"
    ++ msg ++
        \\","data":null}
    );
}

fn respondSuccess(
    r: *routes.ConcatStream,
    id: []const u8,
    account: []const u8,
    token: []const u8,
) !void {
    try r.appendConstant(
        \\{"retcode":0,"message":"OK","data":{"token":{"token_type":1,"token":"
    );

    try r.append(token);

    try r.appendConstant(
        \\"},"user_info":{"aid":"
    );

    try r.append(id);

    try r.appendConstant(
        \\","mid":"
    );

    try r.append(id);

    try r.appendConstant(
        \\","account_name":"","email":"
    );

    try r.append(account);

    try r.appendConstant(
        \\@xeondev.com","is_email_verify":0,"area_code":"**","mobile":"","safe_area_code":"","safe_mobile":"","realname":"","identity_code":"","rebind_area_code":"","rebind_mobile":"","rebind_mobile_time":"228","links":[],"country":"RU","password_time":"1337","is_adult":1,"unmasked_email":"","unmasked_email_type":0},"ext_user_info":{"guardian_email":"","birth":"0"},"reactivate_action_ticket":"","bind_email_action_ticket":""}}
    );
}
