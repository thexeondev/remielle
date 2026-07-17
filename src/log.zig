const builtin = @import("builtin");
const native_os = builtin.os.tag;

const std = @import("std");

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [64]u8 = undefined;

    var writer: Writer = .init(std.Io.File.stderr().handle, &buffer);
    const terminal: std.Io.Terminal = .{
        .writer = &writer.interface,
        .mode = .escape_codes,
    };

    std.log.defaultLogFileTerminal(level, scope, format, args, terminal) catch {};
    writer.interface.flush() catch {};
}

const Writer = struct {
    file: std.Io.File.Handle,
    interface: std.Io.Writer,

    pub fn init(file: std.Io.File.Handle, buffer: []u8) Writer {
        return .{
            .file = file,
            .interface = .{
                .buffer = buffer,
                .vtable = &.{
                    .drain = switch (native_os) {
                        .windows => drainWindows,
                        else => drainPosix,
                    },
                },
            },
        };
    }

    fn drainPosix(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const writer: *Writer = @alignCast(@fieldParentPtr("interface", io_w));

        var splat_backup_buffer: [64]u8 = undefined;
        var iovecs_buffer: [16]std.posix.iovec_const = undefined;
        var iovecs_count: usize = 0;

        if (io_w.end != 0)
            _ = addVec(&iovecs_buffer, &iovecs_count, io_w.buffer[0..io_w.end]);

        // `data` -> `iovecs_buffer`
        for (data[0 .. data.len - 1]) |buf| {
            if (!addVec(&iovecs_buffer, &iovecs_count, buf))
                break;
        } else {
            const pattern = data[data.len - 1];

            if (iovecs_count != iovecs_buffer.len) switch (splat) {
                0 => {},
                1 => _ = addVec(&iovecs_buffer, &iovecs_count, pattern),
                else => amortize_splat: switch (pattern.len) {
                    0 => {},
                    1 => {
                        @memset(&splat_backup_buffer, pattern[0]);
                        var remaining_splat = splat;

                        while (remaining_splat >= splat_backup_buffer.len) : (remaining_splat -= splat_backup_buffer.len) {
                            if (!addVec(&iovecs_buffer, &iovecs_count, &splat_backup_buffer))
                                // Ran out of iovecs
                                break :amortize_splat;
                        }

                        _ = addVec(&iovecs_buffer, &iovecs_count, splat_backup_buffer[0..remaining_splat]);
                    },
                    else => for (0..splat) |_|
                        if (!addVec(&iovecs_buffer, &iovecs_count, pattern))
                            break :amortize_splat,
                },
            };
        }

        if (iovecs_count == 0) {
            @branchHint(.cold);
            return 0;
        }

        const rc = std.posix.system.writev(writer.file, &iovecs_buffer, @intCast(iovecs_count));
        const written: usize = switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => return error.WriteFailed,
        };

        if (io_w.end == 0) return written;

        if (written >= io_w.end) {
            io_w.end = 0;
            return written - io_w.end;
        } else {
            _ = io_w.consume(written);
            return 0;
        }
    }

    fn addVec(iovecs: []std.posix.iovec_const, count: *usize, data: []const u8) bool {
        if (data.len == 0) return true;
        if (iovecs.len == count.*) return false;

        defer count.* += 1;

        iovecs[count.*] = .{ .base = data.ptr, .len = @intCast(data.len) };
        return true;
    }

    fn drainWindows(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = splat;
        const writer: *Writer = @alignCast(@fieldParentPtr("interface", io_w));

        // Because Windows doesn't have sane vectored I/O API for files,
        // let the Io.Writer amortize drains by utilizing its own buffer.

        if (io_w.end != 0) {
            const written = try writeOneWindows(writer.file, io_w.buffer[0..io_w.end]);
            _ = io_w.consume(written);
            return 0;
        }

        if (data[0].len != 0)
            return writeOneWindows(writer.file, data[0]);

        return 0;
    }

    fn writeOneWindows(file: std.Io.File.Handle, buf: []const u8) std.Io.Writer.Error!usize {
        const w = std.os.windows;

        var iosb: w.IO_STATUS_BLOCK = undefined;
        return switch (w.ntdll.NtWriteFile(
            file,
            null, // Event
            null, // ApcRoutine
            null, // ApcContext
            &iosb,
            buf.ptr,
            @truncate(buf.len),
            null, // ByteOffset
            null, // Key
        )) {
            .SUCCESS => @intCast(iosb.Information),
            else => error.WriteFailed,
        };
    }
};
