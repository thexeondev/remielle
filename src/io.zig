const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const build_options = @import("build_options");

pub const Evented = @import("io/Evented.zig");
pub const MultiSocket = @import("io/MultiSocket.zig");

test {
    std.testing.refAllDecls(@This());
}

pub const Mode = enum {
    evented,
    threaded,

    /// Prefers `evented` if it's supported.
    pub const preferred: Mode = if (Evented.supported)
        .evented
    else
        .threaded;

    /// Based on `io_mode` build option.
    pub const configured: Mode = switch (build_options.io_mode) {
        .default => .preferred,
        .threaded => .threaded,
        .evented => evented: {
            if (!Evented.supported)
                @compileError("Evented I/O is not supported by the target");

            break :evented .evented;
        },
    };
};

pub fn waitForShutdownThreaded(threaded: *Io.Threaded) void {
    const shared = struct {
        var threaded_io: Io = undefined;
        var event: Io.Event = .unset;
        var once: std.atomic.Value(bool) = .init(false);
    };

    assert(!shared.once.swap(true, .monotonic)); // `waitForShutdownThreaded` was called twice.

    const threaded_io = threaded.io();
    shared.threaded_io = threaded_io;

    if (is_windows) {
        const w = std.os.windows;

        const windows = struct {
            const PHANDLER_ROUTINE = *const fn (w.DWORD) callconv(.winapi) w.BOOL;

            extern "kernel32" fn SetConsoleCtrlHandler(
                PHANDLER_ROUTINE,
                w.BOOL,
            ) callconv(.winapi) w.BOOL;

            fn handler(_: w.DWORD) callconv(.winapi) w.BOOL {
                shared.event.set(shared.threaded_io);
                return .TRUE;
            }
        };

        assert(windows.SetConsoleCtrlHandler(windows.handler, .TRUE) != .FALSE);
    } else {
        const system = std.posix.system;

        const posix = struct {
            fn handler(_: system.SIG) callconv(.c) void {
                shared.event.set(shared.threaded_io);
            }
        };

        assert(system.sigaction(
            .INT,
            &.{
                .handler = .{ .handler = posix.handler },
                .mask = std.mem.zeroes(@FieldType(system.Sigaction, "mask")),
                .flags = 0,
            },
            null,
        ) == 0);
    }

    shared.event.waitUncancelable(shared.threaded_io);
}
