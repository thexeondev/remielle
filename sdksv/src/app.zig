const log = std.log.scoped(.@"remielle-sdksv");

const accept_backlog: u31 = 100;
const buffer_size: usize = 16384;

pub fn listen(
    io: Io,
    gpa: Allocator,
    address: *const net.IpAddress,
) Cancelable!void {
    var passwd = Passwd.load(io, gpa, .cwd()) catch |err|
        fatal("failed to load passwd file: {t}", .{err});
    defer passwd.deinit(gpa);

    var server = address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = accept_backlog,
    }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.AddressInUse => fatal(
            "failed to listen at {f}, another instance might be already running",
            .{address},
        ),
        else => |e| fatal("failed to listen at {f}: {t}", .{ address, e }),
    };
    defer server.deinit(io);

    var client_group: Io.Group = .init;
    defer client_group.cancel(io);

    log.info("waiting for requests at {f}", .{server.socket.address});
    defer log.info("shutting down...", .{});

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,

            error.SystemResources,
            error.SystemFdQuotaExceeded,
            error.ProcessFdQuotaExceeded,
            => {
                try io.sleep(.fromSeconds(1), .awake);
                continue;
            },

            error.ProtocolFailure,
            error.BlockedByFirewall,
            error.ConnectionAborted,
            => continue,

            error.WouldBlock,
            error.SocketNotListening,
            => unreachable,

            error.Unexpected,
            error.NetworkDown,
            => |e| fatal("fatal accept error: {t}", .{e}),
        };

        client_group.concurrent(io, serve, .{ io, gpa, &passwd, stream }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                stream.close(io);
                continue;
            },
        };
    }
}

fn serve(io: Io, gpa: Allocator, passwd: *Passwd, stream: net.Stream) Cancelable!void {
    defer stream.close(io);

    var request_buffer: [buffer_size]u8 = undefined;
    var request_reader = stream.reader(io, &request_buffer);
    const reader = &request_reader.interface;

    var unbuffered_writer = stream.writer(io, &.{});
    const writer = &unbuffered_writer.interface;

    while (true) {
        const request = http.Request.receive(routes.Route, reader) catch |err| switch (err) {
            // The client has closed the connection.
            error.EndOfStream => return,

            // A request with too high content-length was skipped.
            error.BodyTooBig => {
                writer.writeAll(
                    "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n",
                ) catch switch (unbuffered_writer.err.?) {
                    error.Canceled => |e| return e,
                    else => return,
                };

                continue;
            },

            // The connection stream is in illegal state.
            error.RequestLineTooLong,
            error.HeaderTooLong,
            error.HeadersMalformed,
            error.IllegalHeaderValue,
            error.IllegalHeaders,
            error.UnsupportedMethod,
            error.MissingComponents,
            => return,

            error.ReadFailed => switch (request_reader.err.?) {
                error.Canceled => |e| return e,
                else => return,
            },
        };

        routes.process(io, gpa, passwd, &request, writer) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.WriteFailed => switch (unbuffered_writer.err.?) {
                error.Canceled => |e| return e,
                else => return,
            },
            error.NoSpaceLeft, error.NoVectorsLeft => |e| {
                log.err("failed to respond to {?t}: {t}", .{ request.path, e });
                return;
            },
            error.BadRequest => {
                writer.writeAll(
                    "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n",
                ) catch switch (unbuffered_writer.err.?) {
                    error.Canceled => |e| return e,
                    else => return,
                };
            },
            error.Internal => {
                writer.writeAll(
                    "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n",
                ) catch switch (unbuffered_writer.err.?) {
                    error.Canceled => |e| return e,
                    else => return,
                };
            },
        };
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cancelable = std.Io.Cancelable;

const net = std.Io.net;

const http = @import("http.zig");
const routes = @import("routes.zig");
const Passwd = @import("Passwd.zig");

const std = @import("std");
