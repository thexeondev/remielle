ring: linux.IoUring,
submissions: std.DoublyLinkedList,
completions: std.DoublyLinkedList,
outstanding: usize,

pub const PathBuffer = struct {
    len: usize,
    bytes: [Io.Dir.max_path_bytes]u8,

    pub fn initPinned(buffer: *PathBuffer, dir: Io.Dir.Handle, path: []const u8) !void {
        _ = dir; // windows-only retardation

        if (path.len >= Io.Dir.max_path_bytes)
            return error.BadPathName;

        @memcpy(buffer.bytes[0..path.len], path);
        buffer.bytes[path.len] = 0;
        buffer.len = path.len;
    }

    inline fn view(buffer: *PathBuffer) [*:0]u8 {
        std.debug.assert(buffer.bytes[buffer.len] == 0);
        return @ptrCast(&buffer.bytes);
    }
};

pub fn init() RemiellIo.InitError!Uring {
    const ring = linux.IoUring.init(256, 0) catch |err| switch (err) {
        error.SystemOutdated,
        error.MemoryMappingNotSupported,
        error.AccessDenied,
        error.PermissionDenied,
        => return error.Unsupported,

        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.LockedMemoryLimitExceeded,
        error.OutOfMemory,
        => return error.SystemResources,

        error.EntriesZero,
        error.EntriesNotPowerOfTwo,
        error.ArgumentsInvalid,
        error.ParamsOutsideAccessibleAddressSpace,
        error.MappingAlreadyExists,
        error.Unexpected,
        => unreachable,
    };

    return .{
        .ring = ring,
        .submissions = .{},
        .completions = .{},
        .outstanding = 0,
    };
}

pub fn deinit(u: *Uring) void {
    u.ring.deinit();
}

pub fn await(u: *Uring) !void {
    u.drainSubmitted();

    if (u.outstanding == 0) {
        // There's nothing to do.
        return;
    } else if (u.completions.first != null) {
        // We have outstanding operations, so it might be useful
        // to flush SQ. However, we should not block here, because
        // there are unacknowledged completions.

        if (u.ring.sq_ready() != 0) _ = u.ring.submit() catch |err| switch (err) {
            error.SignalInterrupt => return,
            else => |e| return e,
        };
    } else {
        // We have outstanding operations and there are no pending completions.
        // Now we can block until anything completes.

        _ = u.ring.submit_and_wait(1) catch |err| switch (err) {
            error.SignalInterrupt => return,
            else => |e| return e,
        };

        u.fillCompleted();
    }
}

fn drainSubmitted(u: *Uring) void {
    while (!u.submissionQueueFull()) {
        const node = u.submissions.popFirst() orelse break;
        const submission: *Operation.Storage.Submission = @alignCast(@fieldParentPtr("node", node));
        const storage: *Operation.Storage = @fieldParentPtr("submission", submission);

        switch (submission.operation) {
            .net_accept => |net_accept| {
                const userdata = &(setUserdata(storage, .{ .net_accept = .{
                    .addr = undefined,
                    .addrlen = @sizeOf(linux.sockaddr.in),
                } }).net_accept);

                _ = u.ring.accept(
                    @intFromPtr(storage),
                    net_accept.listener_handle,
                    @ptrCast(&userdata.addr),
                    &userdata.addrlen,
                    0,
                ) catch unreachable;

                u.outstanding += 1;
            },
            .net_read => |net_read| {
                _ = setUserdata(storage, .{ .net_read = {} });

                _ = u.ring.recv(
                    @intFromPtr(storage),
                    net_read.stream_handle,
                    .{ .buffer = net_read.buffer },
                    0,
                ) catch unreachable;

                u.outstanding += 1;
            },
            .net_write => |net_write| {
                _ = setUserdata(storage, .{ .net_write = .{ .pending_res = 0 } });

                _ = u.ring.writev(
                    @intFromPtr(storage),
                    net_write.stream_handle,
                    @ptrCast(net_write.data),
                    0,
                ) catch unreachable;

                u.outstanding += 1;
            },
            .sleep => |sleep| {
                const userdata = (&setUserdata(storage, .{ .sleep = .{ .timespec = .{
                    .sec = @intCast(@divFloor(sleep.milliseconds, std.time.ms_per_s)),
                    .nsec = @intCast(@mod(sleep.milliseconds, std.time.ms_per_s) * std.time.ns_per_ms),
                } } }).sleep);

                _ = u.ring.timeout(@intFromPtr(storage), &userdata.timespec, 0, 0) catch unreachable;

                u.outstanding += 1;
            },
            .cancel => |cancel| {
                _ = setUserdata(storage, .{ .cancel = {} });

                _ = u.ring.cancel(@intFromPtr(storage), @intFromPtr(cancel.operation), 0) catch unreachable;
                u.outstanding += 1;
            },
            .net_receive => |nrm| {
                const userdata = setUserdata(storage, .{ .net_receive = .{
                    .vector = .{ .base = nrm.buffer.ptr, .len = nrm.buffer.len },
                    .header = undefined,
                    .addr = undefined,
                    .user_addr = nrm.from,
                } });

                userdata.net_receive.header = .{
                    .name = @ptrCast(&userdata.net_receive.addr),
                    .namelen = @sizeOf(linux.sockaddr.in),
                    .iov = (&userdata.net_receive.vector)[0..1].ptr,
                    .iovlen = 1,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };

                _ = u.ring.recvmsg(
                    @intFromPtr(storage),
                    nrm.socket_handle,
                    &userdata.net_receive.header,
                    0,
                ) catch unreachable;

                u.outstanding += 1;
            },
            .net_send => |nsm| {
                const userdata = setUserdata(storage, .{ .net_send = .{
                    .vector = .{ .base = nsm.buffer.ptr, .len = nsm.buffer.len },
                    .header = undefined,
                    .addr = .{
                        .addr = @bitCast(nsm.to.ip4.bytes),
                        .port = std.mem.nativeToBig(u16, nsm.to.ip4.port),
                    },
                    .pending_res = 0,
                } });

                userdata.net_send.header = .{
                    .name = @ptrCast(&userdata.net_send.addr),
                    .namelen = @sizeOf(linux.sockaddr.in),
                    .iov = (&userdata.net_send.vector)[0..1].ptr,
                    .iovlen = 1,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };

                _ = u.ring.sendmsg_zc(
                    @intFromPtr(storage),
                    nsm.socket_handle,
                    &userdata.net_send.header,
                    0,
                ) catch unreachable;

                u.outstanding += 1;
            },
            .dir_open_file => |open| {
                std.debug.assert(open.options.lock == .none); // Not implemented
                _ = setUserdata(storage, .dir_open_file);

                const flags: linux.O = .{
                    .ACCMODE = switch (open.options.mode) {
                        .read_only => .RDONLY,
                        .write_only => .WRONLY,
                        .read_write => .RDWR,
                    },
                    .NOFOLLOW = !open.options.follow_symlinks,
                };

                _ = u.ring.openat(
                    @intFromPtr(storage),
                    open.dir_handle,
                    open.sub_path.view(),
                    flags,
                    0, // mode
                ) catch unreachable;

                u.outstanding += 1;
            },
            .file_read => |read| {
                _ = setUserdata(storage, .file_read);

                _ = u.ring.read(
                    @intFromPtr(storage),
                    read.file_handle,
                    .{ .iovecs = @ptrCast(read.data) },
                    switch (read.mode) {
                        .streaming => std.math.maxInt(u64),
                        .positional => |offset| offset,
                    },
                ) catch unreachable;

                u.outstanding += 1;
            },
            .create_dir => |mkdir| {
                _ = setUserdata(storage, .create_dir);

                _ = u.ring.mkdirat(
                    @intFromPtr(storage),
                    mkdir.at,
                    mkdir.sub_path.view(),
                    mkdir.permissions.toMode(),
                ) catch unreachable;

                u.outstanding += 1;
            },
            .dir_create_file => |create| {
                std.debug.assert(create.options.lock == .none); // Not implemented
                _ = setUserdata(storage, .dir_create_file);

                const flags: linux.O = .{
                    .ACCMODE = if (create.options.read) .RDWR else .WRONLY,
                    .CREAT = true,
                    .TRUNC = create.options.truncate,
                };

                _ = u.ring.openat(
                    @intFromPtr(storage),
                    create.at,
                    create.sub_path.view(),
                    flags,
                    create.options.permissions.toMode(),
                ) catch unreachable;

                u.outstanding += 1;
            },
            .file_write => |write| {
                _ = setUserdata(storage, .file_write);

                _ = u.ring.writev(
                    @intFromPtr(storage),
                    write.file_handle,
                    @ptrCast(write.data),
                    switch (write.mode) {
                        .streaming => std.math.maxInt(u64),
                        .positional => |offset| offset,
                    },
                ) catch unreachable;

                u.outstanding += 1;
            },
            .close => |close| {
                _ = setUserdata(storage, .close);

                _ = u.ring.close(
                    @intFromPtr(storage),
                    close.handle,
                ) catch unreachable;

                u.outstanding += 1;
            },
        }
    }
}

fn submissionQueueFull(u: *Uring) bool {
    const head = @atomicLoad(u32, u.ring.sq.head, .acquire);
    const next = u.ring.sq.sqe_tail +% 1;
    return next -% head > u.ring.sq.sqes.len;
}

fn fillCompleted(u: *Uring) void {
    while (u.ring.cq_ready() != 0) {
        const cqe = u.ring.copy_cqe() catch unreachable;
        const err = cqe.err();

        const storage: *Operation.Storage = @ptrFromInt(cqe.user_data);
        const userdata: *RingUserdata = @ptrCast(&storage.pending.userdata);

        switch (userdata.*) {
            .net_accept => |*net_accept| {
                u.completeOne(storage, .{ .net_accept = switch (err) {
                    .SUCCESS => .{
                        .handle = @intCast(cqe.res),
                        .address = .{ .ip4 = .{
                            .bytes = @bitCast(net_accept.addr.addr),
                            .port = std.mem.bigToNative(u16, net_accept.addr.port),
                        } },
                    },
                    .AGAIN, .FAULT, .INVAL, .NOTSOCK, .OPNOTSUPP => unreachable,
                    .CANCELED => error.Canceled,
                    .MFILE => error.ProcessFdQuotaExceeded,
                    .NFILE => error.SystemFdQuotaExceeded,
                    .NOMEM => error.SystemResources,
                    .CONNABORTED => error.ConnectionAborted,
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .net_read => |*net_read| {
                _ = net_read;

                u.completeOne(storage, .{ .net_read = switch (err) {
                    .SUCCESS => @intCast(cqe.res),
                    .AGAIN, .BADF, .FAULT, .INVAL, .NOTCONN => unreachable,
                    .CANCELED => error.Canceled,
                    .NOMEM => error.SystemResources,
                    .CONNRESET => error.ConnectionResetByPeer,
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .net_write => |*net_write| {
                _ = net_write;

                u.completeOne(storage, .{ .net_write = switch (cqe.err()) {
                    .SUCCESS => @intCast(cqe.res),
                    .AGAIN, .BADF, .FAULT, .INVAL, .NOTCONN => unreachable,
                    .CANCELED => error.Canceled,
                    .NOBUFS, .NOMEM => error.SystemResources,
                    .CONNRESET => error.ConnectionResetByPeer,
                    .PIPE => error.SocketUnconnected,
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .sleep => |*sleep| {
                _ = sleep;
                u.completeOne(storage, .{ .sleep = switch (err) {
                    .SUCCESS, .TIME => {},
                    .CANCELED => error.Canceled,
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .cancel => |*cancel| {
                _ = cancel;
                u.completeOne(storage, .{ .cancel = switch (err) {
                    .SUCCESS => {},
                    .NOENT => {},
                    .ALREADY => {},
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .net_receive => |*nrm| {
                u.completeOne(storage, .{ .net_receive = switch (err) {
                    .SUCCESS => SUCCESS: {
                        nrm.user_addr.* = .{ .ip4 = .{
                            .bytes = @bitCast(nrm.addr.addr),
                            .port = std.mem.bigToNative(u16, nrm.addr.port),
                        } };

                        break :SUCCESS @intCast(cqe.res);
                    },
                    .AGAIN, .BADF, .CONNREFUSED, .FAULT, .INVAL, .NOTCONN => unreachable,
                    .CANCELED => error.Canceled,
                    .NOMEM => error.SystemResources,
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .net_send => |*nsm| {
                const res: i32 = res: {
                    if (cqe.flags & linux.IORING_CQE_F_MORE != 0) {
                        nsm.pending_res = cqe.res;
                        continue;
                    } else if (cqe.flags & linux.IORING_CQE_F_NOTIF != 0) {
                        break :res nsm.pending_res;
                    } else {
                        break :res cqe.res;
                    }
                };

                const cqe_err: linux.E = if (res > -4096 and res < 0)
                    errno(@intCast(-res))
                else
                    .SUCCESS;

                u.completeOne(storage, .{ .net_send = switch (cqe_err) {
                    .SUCCESS => @intCast(res),
                    .AGAIN, .BADF, .FAULT, .INVAL, .NOTCONN => unreachable,
                    .CANCELED => error.Canceled,
                    .NOBUFS, .NOMEM => error.SystemResources,
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .dir_open_file => |*open| {
                _ = open;

                u.completeOne(storage, .{ .dir_open_file = switch (err) {
                    .SUCCESS => @intCast(cqe.res),
                    .BADF, .INVAL => unreachable,
                    .ACCES => error.AccessDenied,
                    .ISDIR => error.IsDir,
                    .NOTDIR => error.NotDir,
                    .BUSY => error.DeviceBusy,
                    .NOENT => error.FileNotFound,
                    .EXIST => error.PathAlreadyExists,
                    .MFILE => error.ProcessFdQuotaExceeded,
                    .NFILE => error.SystemFdQuotaExceeded,
                    .NOMEM => error.SystemResources,
                    .PERM => error.PermissionDenied,
                    .ROFS => error.ReadOnlyFileSystem,
                    .NOSPC => error.NoSpaceLeft,
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .file_read => |*read| {
                _ = read;

                u.completeOne(storage, .{ .file_read = switch (err) {
                    .SUCCESS => @intCast(cqe.res),
                    .BADF, .INVAL => unreachable,
                    .NXIO => error.Unseekable,
                    .SPIPE => error.Unseekable,
                    .OVERFLOW => error.Unseekable,
                    .NOBUFS => error.SystemResources,
                    .NOMEM => error.SystemResources,
                    .IO => error.InputOutput,
                    .ISDIR => error.IsDir,
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .create_dir => |*mkdir| {
                _ = mkdir;

                u.completeOne(storage, .{ .create_dir = switch (err) {
                    .SUCCESS => {},
                    .BADF, .INVAL => unreachable,
                    .ACCES => error.AccessDenied,
                    .PERM => error.PermissionDenied,
                    .DQUOT => error.DiskQuota,
                    .EXIST => error.PathAlreadyExists,
                    .LOOP => error.SymLinkLoop,
                    .MLINK => error.LinkQuotaExceeded,
                    .NAMETOOLONG => error.NameTooLong,
                    .NOENT => error.FileNotFound,
                    .NOMEM => error.SystemResources,
                    .NOSPC => error.NoSpaceLeft,
                    .NOTDIR => error.NotDir,
                    .ROFS => error.ReadOnlyFileSystem,
                    .ILSEQ => error.BadPathName,
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .dir_create_file => |*create| {
                _ = create;

                u.completeOne(storage, .{ .dir_create_file = switch (err) {
                    .SUCCESS => @intCast(cqe.res),
                    .BADF, .INVAL => unreachable,
                    .ACCES => error.AccessDenied,
                    .ISDIR => error.IsDir,
                    .NOTDIR => error.NotDir,
                    .BUSY => error.DeviceBusy,
                    .NOENT => error.FileNotFound,
                    .EXIST => error.PathAlreadyExists,
                    .MFILE => error.ProcessFdQuotaExceeded,
                    .NFILE => error.SystemFdQuotaExceeded,
                    .NOMEM => error.SystemResources,
                    .PERM => error.PermissionDenied,
                    .ROFS => error.ReadOnlyFileSystem,
                    .NOSPC => error.NoSpaceLeft,
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .file_write => |*write| {
                _ = write;

                u.completeOne(storage, .{ .file_write = switch (err) {
                    .SUCCESS => @intCast(cqe.res),
                    .INVAL => unreachable,
                    .BADF => error.NotOpenForWriting,
                    .DQUOT => error.DiskQuota,
                    .FBIG => error.FileTooBig,
                    .IO => error.InputOutput,
                    .NOSPC => error.NoSpaceLeft,
                    .PERM => error.PermissionDenied,
                    .PIPE => error.BrokenPipe,
                    .NXIO => error.Unseekable,
                    else => |e| unexpected(e),
                } });

                u.outstanding -= 1;
            },
            .close => |*close| {
                _ = close;

                u.completeOne(storage, .{ .close = {} });
                u.outstanding -= 1;
            },
        }
    }
}

const RingUserdata = union(enum) {
    comptime {
        std.debug.assert(@sizeOf(RingUserdata) <= @sizeOf(@FieldType(Operation.Storage.Pending, "userdata")));
    }

    net_accept: struct {
        addr: linux.sockaddr.in,
        addrlen: linux.socklen_t,
    },
    net_read: void,
    net_write: struct {
        pending_res: i32,
    },
    sleep: struct {
        timespec: linux.kernel_timespec,
    },
    cancel: void,
    net_receive: struct {
        addr: linux.sockaddr.in,
        header: linux.msghdr,
        vector: std.posix.iovec,
        user_addr: *Io.net.IpAddress,
    },
    net_send: struct {
        addr: linux.sockaddr.in,
        header: linux.msghdr_const,
        vector: std.posix.iovec_const,
        pending_res: i32,
    },
    dir_open_file: void,
    file_read: void,
    create_dir: void,
    dir_create_file: void,
    file_write: void,
    close: void,
};

fn setUserdata(storage: *Operation.Storage, userdata: RingUserdata) *RingUserdata {
    storage.* = .{ .pending = .{ .userdata = undefined } };
    const ptr: *RingUserdata = @ptrCast(&storage.pending.userdata);
    ptr.* = userdata;

    return ptr;
}

fn completeOne(u: *Uring, storage: *Operation.Storage, result: Operation.Result) void {
    storage.* = .{ .completion = .{
        .result = result,
        .node = .{},
    } };

    u.completions.append(&storage.completion.node);
}

pub fn netBind(
    u: *Uring,
    address: *const Io.net.IpAddress,
    options: Io.net.IpAddress.BindOptions,
    reuse_address: bool,
) Io.net.IpAddress.BindError!Io.net.Socket {
    _ = u;

    const socket_type: u32 = switch (options.mode) {
        .stream => linux.SOCK.STREAM,
        .dgram => linux.SOCK.DGRAM,
        else => return error.SocketModeUnsupported,
    };

    const protocol: u32 = switch (options.protocol orelse .udp) {
        .tcp => linux.IPPROTO.TCP,
        .udp => linux.IPPROTO.UDP,
        else => return error.ProtocolUnsupportedBySystem,
    };

    const rc = linux.socket(linux.AF.INET, socket_type, protocol);
    switch (errno(rc)) {
        .SUCCESS => {},
        .ACCES => return error.AddressUnavailable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        .INVAL, .AFNOSUPPORT, .PROTONOSUPPORT => unreachable,
        else => |e| unexpected(e),
    }

    const socket: fd_t = @intCast(rc);
    errdefer _ = linux.close(socket);

    if (reuse_address) {
        var optval: u32 = 1;
        switch (errno(linux.setsockopt(socket, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&optval), @sizeOf(u32)))) {
            .SUCCESS => {},
            .BADF, .FAULT, .INVAL, .NOPROTOOPT, .NOTSOCK => unreachable,
            else => |e| unexpected(e),
        }

        switch (errno(linux.setsockopt(socket, linux.SOL.SOCKET, linux.SO.REUSEPORT, @ptrCast(&optval), @sizeOf(u32)))) {
            .SUCCESS => {},
            .BADF, .FAULT, .INVAL, .NOPROTOOPT, .NOTSOCK => unreachable,
            else => |e| unexpected(e),
        }
    }

    var sockaddr: linux.sockaddr.in = .{
        .addr = @bitCast(address.ip4.bytes),
        .port = std.mem.nativeToBig(u16, address.ip4.port),
    };

    switch (errno(linux.bind(socket, @ptrCast(&sockaddr), @sizeOf(linux.sockaddr.in)))) {
        .SUCCESS => {},
        .ACCES => return error.AddressUnavailable,
        .ADDRINUSE => return error.AddressInUse,
        .BADF, .INVAL, .NOTSOCK => unreachable,
        else => |e| unexpected(e),
    }

    return .{
        .handle = socket,
        .address = switch (address.ip4.port) {
            0 => getsockname: {
                var addrlen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
                break :getsockname switch (linux.errno(linux.getsockname(
                    socket,
                    @ptrCast(&sockaddr),
                    &addrlen,
                ))) {
                    .SUCCESS => .{ .ip4 = .{
                        .bytes = @bitCast(sockaddr.addr),
                        .port = std.mem.bigToNative(u16, sockaddr.port),
                    } },
                    else => |e| unexpected(e),
                };
            },
            else => address.*,
        },
    };
}

pub fn netListen(
    u: *Uring,
    address: *const Io.net.IpAddress,
    options: Io.net.IpAddress.ListenOptions,
) Io.net.IpAddress.ListenError!Io.net.Socket {
    const socket = try u.netBind(address, .{
        .mode = .stream,
        .protocol = .tcp,
    }, options.reuse_address);

    errdefer _ = linux.close(socket.handle);

    switch (errno(linux.listen(socket.handle, options.kernel_backlog))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .BADF, .NOTSOCK, .OPNOTSUPP => unreachable,
        else => |e| unexpected(e),
    }

    return socket;
}

pub fn getTime(clock: Io.Clock) Io.Timestamp {
    const CLOCK = std.posix.CLOCK;

    const clock_id = switch (clock) {
        .real => CLOCK.REALTIME,
        .awake => CLOCK.MONOTONIC,
        .boot => CLOCK.BOOTTIME,
        .cpu_process => CLOCK.PROCESS_CPUTIME_ID,
        .cpu_thread => unreachable, // has to be handled by higher level code
    };

    var timespec: linux.timespec = undefined;
    return switch (linux.errno(linux.clock_gettime(clock_id, &timespec))) {
        .SUCCESS => .{ .nanoseconds = @intCast(@as(i128, timespec.sec) * std.time.ns_per_s + timespec.nsec) },
        else => .zero,
    };
}

pub const Mutability = enum {
    @"var",
    @"const",
};

pub fn Vector(mut: Mutability) type {
    return extern struct {
        pub const Slice = switch (mut) {
            .@"var" => []u8,
            .@"const" => []const u8,
        };

        inner: switch (mut) {
            .@"var" => std.posix.iovec,
            .@"const" => std.posix.iovec_const,
        },

        pub fn init(slice: Slice) @This() {
            return .{ .inner = .{
                .base = slice.ptr,
                .len = slice.len,
            } };
        }
    };
}

fn unexpected(e: linux.E) noreturn {
    if (is_debug)
        panic("unexpected errno: {t}", .{e})
    else
        abort();
}

const is_debug = builtin.mode == .Debug;

const fd_t = linux.fd_t;
const errno = linux.errno;
const linux = std.os.linux;
const panic = std.debug.panic;
const abort = std.process.abort;

const Io = std.Io;
const Operation = RemiellIo.Operation;

const RemiellIo = @import("../RemiellIo.zig");
const builtin = @import("builtin");
const std = @import("std");
const Uring = @This();
