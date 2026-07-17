port: windows.HANDLE,
submissions: std.DoublyLinkedList,
completions: std.DoublyLinkedList,
outstanding: usize,

pub const PathBuffer = @import("Iocp/PathBuffer.zig");

pub fn init() RemiellIo.InitError!Iocp {
    var data: ws2_32.WSADATA = undefined;
    switch (ws2_32.WSAStartup(0x0202, &data)) {
        0 => {},
        else => |rc| return switch (@as(ws2_32.WinsockError, @enumFromInt(@as(u16, @intCast(rc))))) {
            .WSASYSNOTREADY, .WSAVERNOTSUPPORTED => error.Unsupported,
            .WSAEPROCLIM => error.SystemResources,
            else => |e| unexpectedWsa(e),
        },
    }

    const port = kernel32.CreateIoCompletionPort(
        windows.INVALID_HANDLE_VALUE,
        null,
        0,
        0,
    ) orelse return unexpectedWin32(windows.GetLastError());

    return .{
        .port = port,
        .submissions = .{},
        .completions = .{},
        .outstanding = 0,
    };
}

pub fn deinit(iocp: *Iocp) void {
    windows.CloseHandle(iocp.port);
    _ = ws2_32.WSACleanup();
}

pub fn await(iocp: *Iocp) Io.UnexpectedError!void {
    iocp.drainSubmitted();

    if (iocp.outstanding == 0 or iocp.completions.first != null)
        // We should not block here if there are unacknowledged completions.
        return;

    var cpe_buffer: [64]kernel32.OVERLAPPED_ENTRY = undefined;
    var cpes: u32 = 0;

    while (true) {
        if (kernel32.GetQueuedCompletionStatusEx(
            iocp.port,
            &cpe_buffer,
            @truncate(cpe_buffer.len),
            &cpes,
            std.math.maxInt(u32),
            .TRUE,
        ) == .FALSE) return switch (windows.GetLastError()) {
            .EXE_MARKED_INVALID => return, // WAIT_IO_COMPLETION - thread alerted.
            else => |e| return unexpectedWin32(e),
        };

        break;
    }

    iocp.fillCompleted(cpe_buffer[0..cpes]);
}

fn drainSubmitted(iocp: *Iocp) void {
    while (iocp.submissions.popFirst()) |node| {
        const submission: *Operation.Storage.Submission = @alignCast(@fieldParentPtr("node", node));
        const storage: *Operation.Storage = @fieldParentPtr("submission", submission);

        switch (submission.operation) {
            .net_accept => |*net_accept| {
                const listen_socket = net_accept.listener_handle;

                const accept_socket = openIpSocket(ws2_32.SOCK.STREAM, ws2_32.IPPROTO.TCP) catch |err| {
                    iocp.completeOne(storage, .{ .net_accept = err });
                    continue;
                };

                const userdata = setExtra(storage, listen_socket, .{ .net_accept = .{
                    .buffer = undefined,
                    .listen_socket = listen_socket,
                    .accept_socket = accept_socket,
                } });

                const buffer = &userdata.extra.net_accept.buffer;

                var bytes_received: u32 = 0;

                if (ws2_32.AcceptEx(
                    listen_socket,
                    accept_socket,
                    buffer.ptr,
                    0,
                    OverlappedUserdata.sockaddr_size,
                    OverlappedUserdata.sockaddr_size,
                    &bytes_received,
                    &userdata.overlapped,
                ) != .FALSE) {
                    // The operation has completed already,
                    // however, it'll still deliver a completion to the port.
                    iocp.outstanding += 1;
                    continue;
                } else switch (ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAEINVAL, .WSAENOTSOCK => unreachable,
                    .WSA_IO_PENDING => {
                        iocp.outstanding += 1;
                        continue;
                    },
                    else => |e| iocp.completeOne(storage, .{ .net_accept = unexpectedWsa(e) }),
                }
            },
            .net_read => |*net_read| {
                const socket = net_read.stream_handle;

                const userdata = setExtra(storage, socket, .{ .net_read = .{
                    .buffer = .{
                        .len = @truncate(net_read.buffer.len),
                        .buf = net_read.buffer.ptr,
                    },
                    .recv_flags = 0,
                } });

                if (ws2_32.WSARecv(
                    socket,
                    @ptrCast(&userdata.extra.net_read.buffer),
                    1,
                    null,
                    &userdata.extra.net_read.recv_flags,
                    &userdata.overlapped,
                    null,
                ) != ws2_32.SOCKET_ERROR) {
                    // The operation has completed already,
                    // however, it'll still deliver a completion to the port.
                    iocp.outstanding += 1;
                    continue;
                } else iocp.completeOne(storage, .{ .net_read = switch (ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAEINVAL, .WSAENOTSOCK => unreachable,
                    .WSAECONNRESET, .WSAENETRESET => error.ConnectionResetByPeer,
                    .WSA_IO_PENDING => {
                        iocp.outstanding += 1;
                        continue;
                    },
                    else => |e| unexpectedWsa(e),
                } });
            },
            .net_write => |*net_write| {
                const socket = net_write.stream_handle;
                const bufs = net_write.data;

                const userdata = setExtra(storage, socket, .{ .net_write = .{} });

                if (ws2_32.WSASend(
                    socket,
                    @ptrCast(bufs.ptr),
                    @intCast(bufs.len),
                    null,
                    0,
                    &userdata.overlapped,
                    null,
                ) != ws2_32.SOCKET_ERROR) {
                    // The operation has completed already,
                    // however, it'll still deliver a completion to the port.
                    iocp.outstanding += 1;
                    continue;
                } else iocp.completeOne(storage, .{ .net_write = switch (ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAEINVAL, .WSAENOTSOCK => unreachable,
                    .WSAECONNRESET, .WSAENETRESET => error.ConnectionResetByPeer,
                    .WSA_IO_PENDING => {
                        iocp.outstanding += 1;
                        continue;
                    },
                    else => |e| unexpectedWsa(e),
                } });
            },
            .sleep => |*sleep| {
                const timer = kernel32.CreateWaitableTimerW(
                    null,
                    .FALSE,
                    null,
                ) orelse {
                    unexpectedWin32(windows.GetLastError()) catch {};
                    iocp.completeOne(storage, .{ .sleep = {} });
                    continue;
                };

                var due_time: windows.LARGE_INTEGER = -(@as(i64, @intCast(sleep.milliseconds)) * 10_000);

                const userdata = setExtra(storage, timer, .{ .sleep = .{
                    .completion_port = iocp.port,
                    .state = .pending,
                } });

                if (kernel32.SetWaitableTimer(
                    timer,
                    &due_time,
                    0,
                    sleepTimerCallback,
                    userdata,
                    .FALSE,
                ) == .FALSE) {
                    unexpectedWin32(windows.GetLastError()) catch {};
                    iocp.completeOne(storage, .{ .sleep = {} });
                    continue;
                }

                iocp.outstanding += 1;
            },
            .cancel => |*cancel| {
                const cancel_userdata: *OverlappedUserdata = @ptrCast(&cancel.operation.pending.userdata);

                switch (cancel_userdata.extra) {
                    .net_accept, .net_write, .net_read, .net_receive, .net_send => {
                        iocp.completeOne(storage, .{
                            .cancel = if (kernel32.CancelIoEx(
                                cancel_userdata.handle,
                                &cancel_userdata.overlapped,
                            ) == .FALSE) switch (windows.GetLastError()) {
                                .NOT_FOUND => {},
                                else => |e| unexpectedWin32(e) catch {},
                            } else {},
                        });
                    },
                    .sleep => switch (@atomicRmw(
                        OperationState,
                        &cancel_userdata.extra.sleep.state,
                        .Xchg,
                        .canceled,
                        .seq_cst,
                    )) {
                        .pending => {
                            var due_time: windows.LARGE_INTEGER = -1;
                            _ = kernel32.SetWaitableTimer(
                                cancel_userdata.handle,
                                &due_time,
                                0,
                                sleepTimerCallback,
                                cancel_userdata,
                                .FALSE,
                            );

                            iocp.completeOne(storage, .{ .cancel = {} });
                        },
                        .finished, .canceled => iocp.completeOne(storage, .{
                            .cancel = {},
                        }),
                    },
                }
            },
            .net_receive => |*nrm| {
                const socket = nrm.socket_handle;

                const userdata = setExtra(storage, socket, .{ .net_receive = .{
                    .buffer = .{
                        .len = @truncate(nrm.buffer.len),
                        .buf = nrm.buffer.ptr,
                    },
                    .recv_flags = 0,
                    .from = undefined,
                    .from_len = @sizeOf(ws2_32.sockaddr.in),
                    .user_addr = nrm.from,
                } });

                if (ws2_32.WSARecvFrom(
                    socket,
                    @ptrCast(&userdata.extra.net_receive.buffer),
                    1,
                    null,
                    &userdata.extra.net_receive.recv_flags,
                    @ptrCast(&userdata.extra.net_receive.from),
                    &userdata.extra.net_receive.from_len,
                    &userdata.overlapped,
                    null,
                ) != ws2_32.SOCKET_ERROR) {
                    // The operation has completed already,
                    // however, it'll still deliver a completion to the port.
                    iocp.outstanding += 1;
                    continue;
                } else iocp.completeOne(storage, .{ .net_receive = switch (ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAEINVAL, .WSAENOTSOCK => unreachable,
                    .WSAEMSGSIZE => error.MessageOversize,
                    .WSA_IO_PENDING => {
                        iocp.outstanding += 1;
                        continue;
                    },
                    else => |e| unexpectedWsa(e),
                } });
            },
            .net_send => |*nsm| {
                const socket = nsm.socket_handle;

                const userdata = setExtra(storage, socket, .{ .net_send = .{
                    .buffer = .{
                        .len = @truncate(nsm.buffer.len),
                        .buf = nsm.buffer.ptr,
                    },
                    .to = .{
                        .addr = @bitCast(nsm.to.ip4.bytes),
                        .port = std.mem.nativeToBig(u16, nsm.to.ip4.port),
                    },
                } });

                if (ws2_32.WSASendTo(
                    socket,
                    @ptrCast(&userdata.extra.net_send.buffer),
                    1,
                    null,
                    0,
                    @ptrCast(&userdata.extra.net_send.to),
                    @sizeOf(ws2_32.sockaddr.in),
                    &userdata.overlapped,
                    null,
                ) != ws2_32.SOCKET_ERROR) {
                    // The operation has completed already,
                    // however, it'll still deliver a completion to the port.
                    iocp.outstanding += 1;
                    continue;
                } else iocp.completeOne(storage, .{ .net_send = switch (ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAEINVAL, .WSAENOTSOCK => unreachable,
                    .WSAENOBUFS => error.SystemResources,
                    .WSAEMSGSIZE => error.MessageOversize,
                    .WSA_IO_PENDING => {
                        iocp.outstanding += 1;
                        continue;
                    },
                    else => |e| unexpectedWsa(e),
                } });
            },
            .dir_open_file => |*open| {
                const sub_path_w = open.sub_path.space.span();
                const dir_handle = if (Io.Dir.path.isAbsoluteWindowsWtf16(sub_path_w))
                    null
                else
                    open.dir_handle;

                const allow_directory = open.options.allow_directory and !open.options.isWrite();

                var iosb: windows.IO_STATUS_BLOCK = undefined;
                var result: windows.HANDLE = undefined;

                iocp.completeOne(storage, .{
                    .dir_open_file = switch (windows.ntdll.NtCreateFile(
                        &result,
                        .{
                            .STANDARD = .{ .SYNCHRONIZE = true },
                            .GENERIC = .{
                                .READ = open.options.isRead(),
                                .WRITE = open.options.isWrite(),
                            },
                        },
                        &.{
                            .RootDirectory = dir_handle,
                            .ObjectName = @constCast(&windows.UNICODE_STRING.init(sub_path_w)),
                        },
                        &iosb,
                        null,
                        .{ .NORMAL = true },
                        .VALID_FLAGS,
                        .OPEN,
                        .{
                            .IO = if (open.options.follow_symlinks) .SYNCHRONOUS_NONALERT else .ASYNCHRONOUS,
                            .NON_DIRECTORY_FILE = !allow_directory,
                            .OPEN_REPARSE_POINT = !open.options.follow_symlinks,
                        },
                        null,
                        0,
                    )) {
                        .SUCCESS => result,
                        .OBJECT_NAME_INVALID => error.BadPathName,
                        .OBJECT_NAME_NOT_FOUND => error.FileNotFound,
                        .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
                        .BAD_NETWORK_PATH => error.NetworkNotFound, // \\server was not found
                        .BAD_NETWORK_NAME => error.NetworkNotFound, // \\server was found but \\server\share wasn't
                        .NO_MEDIA_IN_DEVICE => error.NoDevice,
                        .ACCESS_DENIED => error.AccessDenied,
                        .PIPE_BUSY => error.PipeBusy,
                        .PIPE_NOT_AVAILABLE => error.NoDevice,
                        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
                        .FILE_IS_A_DIRECTORY => error.IsDir,
                        .NOT_A_DIRECTORY => error.NotDir,
                        .USER_MAPPED_FILE => error.AccessDenied,
                        .VIRUS_INFECTED, .VIRUS_DELETED => error.AntivirusInterference,
                        else => |status| unexpectedNtStatus(status),
                    },
                });
            },
            .file_read => |read| {
                var iosb: windows.IO_STATUS_BLOCK = undefined;
                const byte_offset: ?*const windows.LARGE_INTEGER = switch (read.mode) {
                    .streaming => null,
                    .positional => |*offset| @ptrCast(offset),
                };

                // TODO: use overlapped I/O
                iocp.completeOne(storage, .{
                    .file_read = switch (windows.ntdll.NtReadFile(
                        read.file_handle,
                        null, // Event,
                        null, // ApcRoutine
                        null, // ApcContext
                        &iosb,
                        read.data.ptr,
                        @truncate(read.data.len),
                        byte_offset,
                        null, // Key
                    )) {
                        .SUCCESS => @intCast(iosb.Information),
                        .END_OF_FILE, .PIPE_BROKEN => 0,
                        .INVALID_HANDLE => error.NotOpenForReading,
                        .INVALID_DEVICE_REQUEST => error.IsDir,
                        .FILE_LOCK_CONFLICT => error.LockViolation,
                        .ACCESS_DENIED => error.AccessDenied,
                        else => |status| unexpectedNtStatus(status),
                    },
                });
            },
            .create_dir => |mkdir| {
                const attr: windows.OBJECT.ATTRIBUTES = .{
                    .RootDirectory = if (Io.Dir.path.isAbsoluteWindowsWtf16(mkdir.sub_path.space.span()))
                        null
                    else
                        mkdir.at,
                    .Attributes = .{ .INHERIT = false },
                    .ObjectName = @constCast(&windows.UNICODE_STRING.init(mkdir.sub_path.space.span())),
                    .SecurityDescriptor = null,
                    .SecurityQualityOfService = null,
                };

                var iosb: windows.IO_STATUS_BLOCK = undefined;
                var child_handle: windows.HANDLE = undefined;

                iocp.completeOne(storage, .{
                    .create_dir = switch (windows.ntdll.NtCreateFile(
                        &child_handle,
                        .{
                            .GENERIC = .{ .READ = true },
                            .STANDARD = .{ .SYNCHRONIZE = true },
                        },
                        &attr,
                        &iosb,
                        null,
                        .{ .NORMAL = true },
                        .VALID_FLAGS,
                        .CREATE,
                        .{
                            .DIRECTORY_FILE = true,
                            .NON_DIRECTORY_FILE = false,
                            .IO = .SYNCHRONOUS_NONALERT,
                            .OPEN_REPARSE_POINT = false,
                        },
                        null,
                        0,
                    )) {
                        .SUCCESS => {
                            _ = NtClose(child_handle);
                        },
                        .OBJECT_NAME_INVALID => error.BadPathName,
                        .OBJECT_NAME_NOT_FOUND => error.FileNotFound,
                        .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
                        .BAD_NETWORK_PATH => error.NetworkNotFound, // \\server was not found
                        .BAD_NETWORK_NAME => error.NetworkNotFound, // \\server was found but \\server\share wasn't
                        .ACCESS_DENIED => error.AccessDenied,
                        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
                        .NOT_A_DIRECTORY => error.NotDir,
                        .USER_MAPPED_FILE => error.AccessDenied,
                        else => |status| unexpectedNtStatus(status),
                    },
                });
            },
            .dir_create_file => |*create| {
                const sub_path_w = create.sub_path.space.span();
                const dir_handle = if (Io.Dir.path.isAbsoluteWindowsWtf16(sub_path_w))
                    null
                else
                    create.at;

                const attr: windows.OBJECT.ATTRIBUTES = .{
                    .RootDirectory = dir_handle,
                    .ObjectName = @constCast(&create.sub_path.space.string()),
                };

                const create_disposition: windows.FILE.CREATE_DISPOSITION = if (create.options.truncate)
                    .OVERWRITE_IF
                else
                    .OPEN_IF;

                const access_mask: windows.ACCESS_MASK = .{
                    .STANDARD = .{ .SYNCHRONIZE = true },
                    .GENERIC = .{
                        .WRITE = true,
                        .READ = create.options.read,
                    },
                };

                var iosb: windows.IO_STATUS_BLOCK = undefined;
                var result: windows.HANDLE = undefined;

                iocp.completeOne(storage, .{
                    .dir_create_file = switch (windows.ntdll.NtCreateFile(
                        &result,
                        access_mask,
                        &attr,
                        &iosb,
                        null,
                        .{ .NORMAL = true },
                        .VALID_FLAGS, // share access
                        create_disposition,
                        .{
                            .NON_DIRECTORY_FILE = true,
                            .IO = .SYNCHRONOUS_NONALERT,
                        },
                        null,
                        0,
                    )) {
                        .SUCCESS => result,
                        .OBJECT_NAME_INVALID => error.BadPathName,
                        .OBJECT_NAME_NOT_FOUND => error.FileNotFound,
                        .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
                        .BAD_NETWORK_PATH => error.NetworkNotFound, // \\server was not found
                        .BAD_NETWORK_NAME => error.NetworkNotFound, // \\server was found but \\server\share wasn't
                        .NO_MEDIA_IN_DEVICE => error.NoDevice,
                        .ACCESS_DENIED => error.AccessDenied,
                        .PIPE_BUSY => error.PipeBusy,
                        .PIPE_NOT_AVAILABLE => error.NoDevice,
                        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
                        .FILE_IS_A_DIRECTORY => error.IsDir,
                        .NOT_A_DIRECTORY => error.NotDir,
                        .USER_MAPPED_FILE => error.AccessDenied,
                        .VIRUS_INFECTED, .VIRUS_DELETED => error.AntivirusInterference,
                        .DISK_FULL => error.NoSpaceLeft,
                        else => |status| unexpectedNtStatus(status),
                    },
                });
            },
            .file_write => |write| {
                var iosb: windows.IO_STATUS_BLOCK = undefined;
                const byte_offset: ?*const windows.LARGE_INTEGER = switch (write.mode) {
                    .streaming => null,
                    .positional => |*offset| @ptrCast(offset),
                };

                // TODO: use overlapped I/O
                iocp.completeOne(storage, .{
                    .file_write = switch (windows.ntdll.NtWriteFile(
                        write.file_handle,
                        null, // Event,
                        null, // ApcRoutine
                        null, // ApcContext
                        &iosb,
                        write.data.ptr,
                        @truncate(write.data.len),
                        byte_offset,
                        null, // Key
                    )) {
                        .SUCCESS => @intCast(iosb.Information),
                        .INVALID_USER_BUFFER => error.SystemResources,
                        .NO_MEMORY => error.SystemResources,
                        .QUOTA_EXCEEDED => error.SystemResources,
                        .PIPE_BROKEN => error.BrokenPipe,
                        .INVALID_HANDLE => error.NotOpenForWriting,
                        .FILE_LOCK_CONFLICT => error.LockViolation,
                        .ACCESS_DENIED => error.AccessDenied,
                        .WORKING_SET_QUOTA => error.SystemResources,
                        .DISK_FULL => error.NoSpaceLeft,
                        else => |status| unexpectedNtStatus(status),
                    },
                });
            },
            .close => unreachable,
        }
    }
}

fn sleepTimerCallback(
    lpArgToCompletionRoutine: ?*anyopaque,
    dwTimerLowValue: windows.DWORD,
    dwTimerHighValue: windows.DWORD,
) callconv(.winapi) void {
    _ = .{ dwTimerLowValue, dwTimerHighValue };

    const userdata: *OverlappedUserdata = @ptrCast(@alignCast(lpArgToCompletionRoutine));
    userdata.overlapped.Internal = @intFromEnum(switch (@atomicRmw(
        OperationState,
        &userdata.extra.sleep.state,
        .Xchg,
        .finished,
        .seq_cst,
    )) {
        .pending => windows.NTSTATUS.SUCCESS,
        .canceled => windows.NTSTATUS.CANCELLED,
        .finished => return,
    });

    _ = kernel32.PostQueuedCompletionStatus(userdata.extra.sleep.completion_port, 0, 0, &userdata.overlapped);
}

fn fillCompleted(iocp: *Iocp, cpes: []const kernel32.OVERLAPPED_ENTRY) void {
    for (cpes) |cpe| {
        const userdata: *OverlappedUserdata = @fieldParentPtr("overlapped", cpe.lpOverlapped);
        const status: windows.NTSTATUS = @enumFromInt(cpe.lpOverlapped.Internal);

        const pending: *Operation.Storage.Pending = @fieldParentPtr(
            "userdata",
            @as(*@FieldType(Operation.Storage.Pending, "userdata"), @ptrCast(userdata)),
        );
        const storage: *Operation.Storage = @fieldParentPtr("pending", pending);

        iocp.completeOne(storage, switch (userdata.extra) {
            .net_accept => .{ .net_accept = switch (status) {
                .SUCCESS => iocp.completeNetAccept(userdata),
                .CANCELLED => error.Canceled,
                .CONNECTION_ABORTED => error.ConnectionAborted,
                else => |rc| unexpectedNtStatus(rc),
            } },
            .net_read => .{ .net_read = switch (status) {
                .SUCCESS => cpe.dwNumberOfBytesTransferred,
                .CANCELLED => error.Canceled,
                .CONNECTION_RESET, .CONNECTION_DISCONNECTED => error.ConnectionResetByPeer,
                .INSUFFICIENT_RESOURCES => error.SystemResources,
                else => |rc| unexpectedNtStatus(rc),
            } },
            .net_write => .{ .net_write = switch (status) {
                .SUCCESS => cpe.dwNumberOfBytesTransferred,
                .CANCELLED => error.Canceled,
                .CONNECTION_RESET, .CONNECTION_DISCONNECTED => error.ConnectionResetByPeer,
                .INSUFFICIENT_RESOURCES => error.SystemResources,
                .PIPE_DISCONNECTED => error.SocketUnconnected,
                else => |rc| unexpectedNtStatus(rc),
            } },
            .sleep => .{
                .sleep = switch (status) {
                    .SUCCESS => {},
                    .CANCELLED => error.Canceled,
                    else => unreachable, // sleepTimerCallback posted an unexpected status
                },
            },
            .net_receive => |*nrm| .{ .net_receive = switch (status) {
                .SUCCESS => SUCCESS: {
                    nrm.user_addr.* = .{ .ip4 = .{
                        .bytes = @bitCast(nrm.from.addr),
                        .port = std.mem.bigToNative(u16, nrm.from.port),
                    } };

                    break :SUCCESS cpe.dwNumberOfBytesTransferred;
                },
                .CANCELLED => error.Canceled,
                .INSUFFICIENT_RESOURCES => error.SystemResources,
                .BUFFER_OVERFLOW => error.MessageOversize,
                else => |rc| unexpectedNtStatus(rc),
            } },
            .net_send => .{ .net_send = switch (status) {
                .SUCCESS => cpe.dwNumberOfBytesTransferred,
                .CANCELLED => error.Canceled,
                .INSUFFICIENT_RESOURCES => error.SystemResources,
                .BUFFER_OVERFLOW => error.MessageOversize,
                else => |rc| unexpectedNtStatus(rc),
            } },
        });

        iocp.outstanding -= 1;
    }
}

const OverlappedUserdata = struct {
    const sockaddr_size = @sizeOf(ws2_32.sockaddr.in) + 16;

    comptime {
        std.debug.assert(@sizeOf(OverlappedUserdata) <= @sizeOf(@FieldType(RemiellIo.Operation.Storage.Pending, "userdata")));
    }

    const Extra = union(enum) {
        net_accept: struct {
            buffer: [2 * sockaddr_size]u8,
            listen_socket: ws2_32.SOCKET,
            accept_socket: ws2_32.SOCKET,
        },
        net_read: struct {
            buffer: ws2_32.WSABUF,
            recv_flags: windows.DWORD,
        },
        net_write: struct {},
        sleep: struct {
            completion_port: windows.HANDLE,
            state: OperationState,
        },
        net_receive: struct {
            buffer: ws2_32.WSABUF,
            recv_flags: windows.DWORD,
            from: ws2_32.sockaddr.in,
            from_len: i32,
            user_addr: *Io.net.IpAddress,
        },
        net_send: struct {
            buffer: ws2_32.WSABUF_const,
            to: ws2_32.sockaddr.in,
        },
    };

    handle: windows.HANDLE, // CancelIoEx requires both handle and overlapped, sigh
    overlapped: kernel32.OVERLAPPED,
    extra: Extra,
};

const OperationState = enum {
    pending,
    canceled,
    finished,
};

fn setExtra(
    storage: *Operation.Storage,
    handle: windows.HANDLE,
    extra: OverlappedUserdata.Extra,
) *OverlappedUserdata {
    storage.* = .{ .pending = .{ .userdata = undefined } };
    const ptr: *OverlappedUserdata = @ptrCast(&storage.pending.userdata);
    ptr.* = .{ .extra = extra, .handle = handle, .overlapped = std.mem.zeroes(kernel32.OVERLAPPED) };

    return ptr;
}

pub fn netBind(
    iocp: *Iocp,
    address: *const Io.net.IpAddress,
    options: Io.net.IpAddress.BindOptions,
    reuse_address: bool,
) Io.net.IpAddress.BindError!Io.net.Socket {
    const socket_type: i32 = switch (options.mode) {
        .stream => ws2_32.SOCK.STREAM,
        .dgram => ws2_32.SOCK.DGRAM,
        else => return error.SocketModeUnsupported,
    };

    const protocol: i32 = switch (options.protocol orelse .udp) {
        .tcp => ws2_32.IPPROTO.TCP,
        .udp => ws2_32.IPPROTO.UDP,
        else => return error.ProtocolUnsupportedBySystem,
    };

    const socket = try openIpSocket(socket_type, protocol);
    errdefer _ = closesocket(socket);

    if (reuse_address) {
        var optval: u32 = 1;
        const rc = ws2_32.setsockopt(socket, ws2_32.SOL.SOCKET, ws2_32.SO.REUSEADDR, @ptrCast(&optval), @sizeOf(u32));
        if (rc == ws2_32.SOCKET_ERROR) return unexpectedWsa(ws2_32.WSAGetLastError());
    }

    var sockaddr: ws2_32.sockaddr.in = .{
        .addr = @bitCast(address.ip4.bytes),
        .port = std.mem.nativeToBig(u16, address.ip4.port),
    };

    if (ws2_32.bind(socket, @ptrCast(&sockaddr), @sizeOf(ws2_32.sockaddr.in)) == ws2_32.SOCKET_ERROR)
        return switch (ws2_32.WSAGetLastError()) {
            .WSANOTINITIALISED => unreachable,
            .WSAEFAULT, .WSAEINVAL, .WSAENOTSOCK, .WSAEADDRNOTAVAIL => unreachable,
            .WSAEACCES => error.AddressUnavailable,
            .WSAEADDRINUSE => error.AddressInUse,
            .WSAENOBUFS => error.SystemResources,
            else => |e| unexpectedWsa(e),
        };

    _ = kernel32.CreateIoCompletionPort(@ptrCast(socket), iocp.port, 0, 0) orelse
        return unexpectedWin32(windows.GetLastError());

    return .{
        .handle = socket,
        .address = switch (address.ip4.port) {
            0 => getsockname: {
                var addrlen: i32 = @sizeOf(ws2_32.sockaddr.in);
                break :getsockname if (ws2_32.getsockname(
                    socket,
                    @ptrCast(&sockaddr),
                    &addrlen,
                ) == ws2_32.SOCKET_ERROR) {
                    return unexpectedWsa(ws2_32.WSAGetLastError());
                } else .{ .ip4 = .{
                    .bytes = @bitCast(sockaddr.addr),
                    .port = std.mem.bigToNative(u16, sockaddr.port),
                } };
            },
            else => address.*,
        },
    };
}

pub fn netListen(
    iocp: *Iocp,
    address: *const Io.net.IpAddress,
    options: Io.net.IpAddress.ListenOptions,
) Io.net.IpAddress.ListenError!Io.net.Socket {
    const socket = try iocp.netBind(address, .{
        .mode = .stream,
        .protocol = .tcp,
    }, options.reuse_address);

    if (ws2_32.listen(socket.handle, options.kernel_backlog) == ws2_32.SOCKET_ERROR)
        return switch (ws2_32.WSAGetLastError()) {
            .WSANOTINITIALISED => unreachable,
            .WSAEFAULT, .WSAEINVAL, .WSAENOTSOCK => unreachable,
            .WSAENOBUFS => error.SystemResources,
            else => |e| unexpectedWsa(e),
        };

    return socket;
}

fn completeNetAccept(iocp: *Iocp, userdata: *OverlappedUserdata) Io.UnexpectedError!Io.net.Socket {
    const net_accept = &userdata.extra.net_accept;

    var local: *ws2_32.sockaddr = undefined;
    var local_len: i32 = 0;

    var remote: *ws2_32.sockaddr = undefined;
    var remote_len: i32 = 0;

    ws2_32.GetAcceptExSockaddrs(
        &net_accept.buffer,
        0,
        OverlappedUserdata.sockaddr_size,
        OverlappedUserdata.sockaddr_size,
        &local,
        &local_len,
        &remote,
        &remote_len,
    );

    _ = ws2_32.setsockopt(
        net_accept.accept_socket,
        ws2_32.SOL.SOCKET,
        ws2_32.SO.UPDATE_ACCEPT_CONTEXT,
        @ptrCast(&net_accept.listen_socket),
        @sizeOf(ws2_32.SOCKET),
    );

    _ = kernel32.CreateIoCompletionPort(@ptrCast(net_accept.accept_socket), iocp.port, 0, 0) orelse
        return unexpectedWin32(windows.GetLastError());

    const remote_in: *ws2_32.sockaddr.in = @ptrCast(@alignCast(remote));

    return .{
        .handle = net_accept.accept_socket,
        .address = .{ .ip4 = .{
            .bytes = @bitCast(remote_in.addr),
            .port = std.mem.bigToNative(u16, remote_in.port),
        } },
    };
}

fn openIpSocket(socket_type: i32, protocol: i32) !ws2_32.SOCKET {
    const socket = ws2_32.WSASocketW(
        ws2_32.AF.INET,
        socket_type,
        protocol,
        null,
        0,
        ws2_32.WSA_FLAG_OVERLAPPED,
    );

    if (socket == ws2_32.INVALID_SOCKET) return switch (ws2_32.WSAGetLastError()) {
        .WSANOTINITIALISED => unreachable, // WSAStartup should've been called by Iocp.init
        .WSAEINPROGRESS => unreachable, // Winsock 1.1 only
        .WSAEAFNOSUPPORT, .WSAEPROTOTYPE, .WSAESOCKTNOSUPPORT => unreachable,
        .WSAENOBUFS => error.SystemResources,
        .WSAEMFILE => error.ProcessFdQuotaExceeded,
        else => |e| unexpectedWsa(e),
    };

    return socket;
}

fn completeOne(iocp: *Iocp, storage: *Operation.Storage, result: Operation.Result) void {
    storage.* = .{ .completion = .{
        .result = result,
        .node = .{},
    } };

    iocp.completions.append(&storage.completion.node);
}

fn unexpectedWsa(e: ws2_32.WinsockError) Io.UnexpectedError {
    if (std.options.unexpected_error_tracing) {
        std.debug.print("unexpected winsock error: {t} ({d})\n", .{ e, @intFromEnum(e) });
        std.debug.dumpCurrentStackTrace(.{});
    }

    return error.Unexpected;
}

fn unexpectedWin32(e: windows.Win32Error) Io.UnexpectedError {
    if (std.options.unexpected_error_tracing) {
        std.debug.print("unexpected win32 error: {t} ({d})\n", .{ e, @intFromEnum(e) });
        std.debug.dumpCurrentStackTrace(.{});
    }

    return error.Unexpected;
}

fn unexpectedNtStatus(e: windows.NTSTATUS) Io.UnexpectedError {
    if (std.options.unexpected_error_tracing) {
        std.debug.print("unexpected NTSTATUS: {t} ({d})\n", .{ e, @intFromEnum(e) });
        std.debug.dumpCurrentStackTrace(.{});
    }

    return error.Unexpected;
}

pub fn getTime(clock: Io.Clock) Io.Timestamp {
    switch (clock) {
        .real => {
            const epoch_ns = std.time.epoch.windows * std.time.ns_per_s;
            return .{ .nanoseconds = @as(i96, windows.ntdll.RtlGetSystemTimePrecise()) * 100 + epoch_ns };
        },
        .awake, .boot => {
            const qpf: u64 = qpf: {
                var qpf: windows.LARGE_INTEGER = undefined;
                if (!windows.ntdll.RtlQueryPerformanceFrequency(&qpf).toBool())
                    return .zero;

                break :qpf @bitCast(qpf);
            };

            const qpc: u64 = qpc: {
                var qpc: windows.LARGE_INTEGER = undefined;
                if (!windows.ntdll.RtlQueryPerformanceCounter(&qpc).toBool())
                    return .zero;

                break :qpc @bitCast(qpc);
            };

            const common_qpf = 10_000_000;
            if (qpf == common_qpf) return .{ .nanoseconds = qpc * (std.time.ns_per_s / common_qpf) };

            const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(qpf));
            const result = (@as(u96, qpc) * scale) >> 32;
            return .{ .nanoseconds = @intCast(result) };
        },
        .cpu_process => {
            const handle = windows.GetCurrentProcess();
            var times: windows.KERNEL_USER_TIMES = undefined;

            if (windows.ntdll.NtQueryInformationProcess(
                handle,
                .Times,
                &times,
                @sizeOf(windows.KERNEL_USER_TIMES),
                null,
            ) != .SUCCESS) return .zero;

            const sum = @as(i96, times.UserTime) + @as(i96, times.KernelTime);
            return .{ .nanoseconds = sum * 100 };
        },
        .cpu_thread => unreachable, // has to be handled by higher level code
    }
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
            .@"var" => ws2_32.WSABUF,
            .@"const" => ws2_32.WSABUF_const,
        },

        pub fn init(slice: Slice) @This() {
            return .{ .inner = .{
                .buf = slice.ptr,
                .len = @intCast(slice.len),
            } };
        }
    };
}

// Re-exported for the higher level code to use.
pub const closesocket = ws2_32.closesocket;
pub const SOCKET = ws2_32.SOCKET;
pub const NtClose = windows.ntdll.NtClose;

const windows = std.os.windows;

const Io = std.Io;
const Operation = RemiellIo.Operation;

const ws2_32 = @import("Iocp/ws2_32.zig");
const kernel32 = @import("Iocp/kernel32.zig");

const RemiellIo = @import("../RemiellIo.zig");
const std = @import("std");
const Iocp = @This();
