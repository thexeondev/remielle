pub const rsa = @import("rsa.zig");
pub const prng = @import("prng.zig");

pub const EncryptAndSignBuffer = struct {
    ciphertext: [encoded_block_size]u8,
    sign: [encoded_block_size]u8,

    pub const encoded_block_size = base64.Encoder.calcSize(rsa.block_size);
};

/// This function uses `rsa.client_public_key` and `rsa.server_private_key`,
/// and encodes the output as base64.
///
/// for a lower level API, see `rsa.encrypt` and `rsa.sign`.
pub fn encryptAndSign(content_block: []const u8, out_buffer: *EncryptAndSignBuffer) void {
    var ciphertext: [rsa.block_size]u8 = undefined;
    var sign: [rsa.block_size]u8 = undefined;

    rsa.client_public_key.encrypt(content_block, &ciphertext);
    rsa.server_private_key.sign(content_block, &sign);

    _ = base64.Encoder.encode(&out_buffer.ciphertext, &ciphertext);
    _ = base64.Encoder.encode(&out_buffer.sign, &sign);
}

const base64 = std.base64.standard;
const std = @import("std");
