const builtin = @import("builtin");
const native_os = builtin.os.tag;

const std = @import("std");

// We cannot use std.debug.print because that will pull std.Io.Threaded via debug_io.
// So we're using direct syscalls instead.

pub fn print() void {
    const stderr: std.Io.File = .stderr();

    writeAll(stderr.handle,
        \\    ____                 _      ____   
        \\   / __ \___  ____ ___  (_)__  / / /__ 
        \\  / /_/ / _ \/ __ `__ \/ / _ \/ / / _ \
        \\ / _, _/  __/ / / / / / /  __/ / /  __/
        \\/_/ |_|\___/_/ /_/ /_/_/\___/_/_/\___/ 
        \\
    ) catch {};
}

fn writeAll(file: std.Io.File.Handle, content: []const u8) !void {
    if (native_os == .windows) {
        const w = std.os.windows;

        var cursor = content;
        var iosb: w.IO_STATUS_BLOCK = undefined;

        while (cursor.len != 0) switch (w.ntdll.NtWriteFile(
            file,
            null, // Event
            null, // ApcRoutine
            null, // ApcContext
            &iosb,
            cursor.ptr,
            @truncate(cursor.len),
            null, // ByteOffset
            null, // Key
        )) {
            .SUCCESS => cursor = cursor[iosb.Information..],
            else => return error.WriteFailed,
        };
    } else {
        var cursor = content;

        while (cursor.len != 0) {
            const rc = std.posix.system.write(file, cursor.ptr, @truncate(cursor.len));
            switch (std.posix.system.errno(rc)) {
                .SUCCESS => cursor = cursor[@bitCast(rc)..],
                else => return error.WriteFailed,
            }
        }
    }
}
