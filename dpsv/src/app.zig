const log = std.log.scoped(.@"remielle-dpsv");

const accept_backlog: u31 = 100;
const buffer_size: usize = 8192;

pub fn listen(
    io: Io,
    data: *const Data,
    address: *const net.IpAddress,
) Io.Cancelable!void {
    var server = address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = accept_backlog,
    }) catch |err| switch (err) {
        error.AddressInUse => fatal(
            "the address {f} is already in use; another instance of this server might be already running",
            .{address},
        ),
        else => |e| fatal("failed to listen at {f}: {t}", .{ address, e }),
    };
    defer server.deinit(io);

    var client_group: Io.Group = .init;
    defer client_group.cancel(io);

    log.info("waiting for requests at http://{f}", .{server.socket.address});
    defer log.info("shutting down...", .{});

    while (true) {
        var stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.SystemResources,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            => {
                try io.sleep(.fromSeconds(1), .awake);
                continue;
            },
            else => |e| {
                log.err("accept: {t}", .{e});
                continue;
            },
        };

        client_group.concurrent(io, serve, .{ io, data, stream }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                stream.close(io);
                continue;
            },
        };
    }
}

fn serve(io: Io, data: *const Data, stream: net.Stream) Io.Cancelable!void {
    // TODO(Io): implement `batchAwaitConcurrent` for `NetRead` to utilize timeouts.
    defer stream.close(io);

    var request_buffer: [buffer_size]u8 = undefined;
    var request_reader = stream.reader(io, &request_buffer);
    const reader = &request_reader.interface;

    var unbuffered_writer = stream.writer(io, &.{});
    const writer = &unbuffered_writer.interface;

    while (true) {
        const request_line = http.RequestLine.parse(reader) catch |err| switch (err) {
            error.ReadFailed => switch (request_reader.err.?) {
                error.Canceled => |e| return e,
                else => return,
            },
            error.StreamTooLong => {
                log.debug(
                    "the request stream from {f} was too long to fit into request_buffer.",
                    .{stream.socket.address},
                );
                return;
            },
            error.EndOfStream,
            error.MissingComponents,
            error.UnsupportedMethod,
            => return,
        };

        var response: routes.Response = .init;
        routes.process(data, &request_line, &response);

        if (!request_line.method.hasResponseBody()) {
            response.body = null;
        }

        var slices_buf: [2][]const u8 = undefined;
        const slices = response.toSlices(&slices_buf);

        writer.writeVecAll(slices) catch |err| switch (err) {
            error.WriteFailed => switch (unbuffered_writer.err.?) {
                error.Canceled => |e| return e,
                else => return,
            },
        };

        discardHeaders(reader) catch |err| switch (err) {
            error.UnexpectedChar, error.EndOfStream => return,
            error.ReadFailed => switch (request_reader.err.?) {
                error.Canceled => |e| return e,
                else => return,
            },
        };
    }
}

fn discardHeaders(reader: *Io.Reader) !void {
    while (true) {
        const discarded = try reader.discardDelimiterInclusive('\r');
        const maybe_newline = try reader.takeByte();
        if (maybe_newline != '\n') return error.UnexpectedChar;

        if (discarded == 1)
            // Only the '\r' itself was discarded, this is the end.
            return;
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

const Io = std.Io;
const Allocator = std.mem.Allocator;

const net = std.Io.net;
const debug = std.debug;

const Data = @import("Data.zig");
const http = @import("http.zig");
const routes = @import("routes.zig");

const std = @import("std");
