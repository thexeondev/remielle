impl: Impl,
gpa: Allocator,
arena: std.heap.ArenaAllocator,
coro_storage: Coroutine.Storage,
current_coro: ?*Coroutine,
naked_wait: WaitPoint,
/// List of coroutines scheduled to be switched to.
wakeup_queue: DoublyLinkedList,
/// List of coroutines waiting on a futex.
wait_list: DoublyLinkedList,
csprng: ?DefaultCsprng,
shutdown: enum(u2) {
    ignored = 0b00,
    waiting = 0b01,
    pending = 0b10,
    acknowledged = 0b11,
},
shutdown_wait_point: *WaitPoint, // Populated by `waitForShutdown`

pub const Impl = switch (native_os) {
    .linux => @import("RemiellIo/Uring.zig"),
    .windows => @import("RemiellIo/Iocp.zig"),
    else => |os_tag| @compileError("Unsupported OS " ++ @tagName(os_tag)),
};

pub const supported = switch (native_os) {
    .linux,
    .windows,
    => true,

    else => false,
};

pub const InitOptions = struct {
    coroutine_limit: Io.Limit,
    stack_size: usize,
};

const WaitPoint = struct {
    awaitee: Awaitee,
    context: Io.fiber.Context,
    wakeup_queue_node: DoublyLinkedList.Node,

    const Awaitee = union(enum) {
        const Futex = struct {
            const Cancelation = enum {
                unblocked,
                blocked, // `futexWaitUncancelable` is used.
                canceled, // `futexWait` was interrupted by cancelation request.
            };

            ptr: *const u32,
            expected: u32,
            cancelation: Cancelation,
            wait_list_node: DoublyLinkedList.Node,
        };

        /// The coroutine is not waiting on anything.
        none: void,
        /// The coroutine is waiting until shutdown sequence is initiated.
        shutdown: void,
        /// The coroutine has finished and is now in an idle state.
        idle: void,
        /// The coroutine is waiting for a `futexWake`.
        futex: Futex,
        /// The coroutine is waiting for an I/O operation to complete.
        operation: struct {
            /// How many operations are in-flight for this coroutine.
            outstanding: u32,
            status: enum {
                waiting_for_one_or_more,
                waiting_for_all,
                scheduled,
            },
        },
        /// The coroutine is waiting for another coroutine to exit.
        coroutine: *Coroutine,
    };
};

pub const InitError = error{
    SystemResources,
    /// The I/O implementation is not supported.
    Unsupported,
} || Allocator.Error || Io.UnexpectedError;

pub fn init(gpa: Allocator, options: InitOptions) InitError!RemiellIo {
    return .{
        .impl = try .init(),
        .gpa = gpa,
        .arena = .init(gpa),
        .coro_storage = .init(options.coroutine_limit, options.stack_size),
        .current_coro = null,
        .naked_wait = .{
            .awaitee = .none,
            .wakeup_queue_node = .{},
            .context = undefined,
        },
        .wakeup_queue = .{},
        .wait_list = .{},
        .csprng = null,
        .shutdown = .ignored,
        .shutdown_wait_point = undefined,
    };
}

pub fn deinit(rio: *RemiellIo) void {
    rio.impl.deinit();
    rio.arena.deinit();
}

/// Treats `Io.Group` as a DoublyLinkedList.
/// Avoids internal allocations for group coroutine tracking.
const Group = struct {
    /// ptr.token is treated as linked list head
    /// ptr.state is treated as linked list tail
    ptr: *Io.Group,

    pub fn append(g: Group, coro: *Coroutine) void {
        if (g.ptr.state != 0) {
            const tail: *DoublyLinkedList.Node = @ptrFromInt(g.ptr.state);
            tail.next = &coro.list_node;
            coro.list_node.prev = tail;
            coro.list_node.next = null;
            g.ptr.state = @intFromPtr(&coro.list_node);
        } else { // empty
            g.ptr.token.raw = &coro.list_node;
            g.ptr.state = @intFromPtr(&coro.list_node);
            coro.list_node.prev = null;
            coro.list_node.next = null;
        }
    }

    pub fn remove(g: Group, coro: *Coroutine) void {
        if (coro.list_node.prev) |prev|
            prev.next = coro.list_node.next
        else
            g.ptr.token.raw = coro.list_node.next;

        if (coro.list_node.next) |next|
            next.prev = coro.list_node.prev
        else
            g.ptr.state = @intFromPtr(coro.list_node.prev);
    }

    pub fn peek(g: Group) ?*Coroutine {
        const node: *DoublyLinkedList.Node = @ptrCast(@alignCast(g.ptr.token.raw orelse return null));
        return @fieldParentPtr("list_node", node);
    }
};

const Coroutine = struct {
    cancelation: Cancelation,
    buffer: []u8,
    scheduling: union(enum) {
        awaitable: struct {
            start: *const fn (context: *const anyopaque, result: *anyopaque) void,
            result_ptr: *anyopaque,
        },
        grouped: struct {
            start: *const fn (context: *const anyopaque) void,
            group: Group,
        },
    },
    context_ptr: *const anyopaque,
    list_node: DoublyLinkedList.Node,
    wait_point: WaitPoint,
    rio: *RemiellIo,
    awaiter: ?*WaitPoint,

    pub fn hasExited(coro: *Coroutine) bool {
        return switch (coro.wait_point.awaitee) {
            .idle => true,
            .none, .shutdown, .futex, .operation, .coroutine => false,
        };
    }

    const Cancelation = packed struct(u3) {
        status: enum(u2) {
            none,
            requested,
            acknowledged,
        },
        protection: Io.CancelProtection,

        const init: Cancelation = .{
            .status = .none,
            .protection = .unblocked,
        };

        fn request(cancelation: *Cancelation) void {
            debug.assert(cancelation.status == .none); // always a race condition
            cancelation.status = .requested;
        }

        fn swapProtection(cancelation: *Cancelation, new: Io.CancelProtection) Io.CancelProtection {
            defer cancelation.protection = new;
            return cancelation.protection;
        }

        fn acknowledge(cancelation: *Cancelation) Io.Cancelable!void {
            switch (cancelation.*) {
                .{ .status = .requested, .protection = .unblocked } => {
                    cancelation.status = .acknowledged;
                    return error.Canceled;
                },
                else => {},
            }
        }
    };

    const Storage = struct {
        limit: Io.Limit,
        stack_size: usize,
        free_list: DoublyLinkedList,

        pub fn init(limit: Io.Limit, stack_size: usize) Storage {
            return .{
                .limit = limit,
                .stack_size = stack_size,
                .free_list = .{},
            };
        }

        pub const AllocateError = Allocator.Error || error{LimitExceeded};

        pub fn allocate(coro_storage: *Storage, arena: Allocator) AllocateError!*Coroutine {
            if (coro_storage.free_list.popFirst()) |node|
                return @alignCast(@fieldParentPtr("list_node", node));

            coro_storage.limit = coro_storage.limit.subtract(1) orelse
                return error.LimitExceeded;

            // TODO: allocate Coroutine.buffer together, as trailing data
            const coro = try arena.create(Coroutine);
            coro.buffer = try arena.alloc(u8, coro_storage.stack_size);

            return coro;
        }

        pub fn recycle(coro_storage: *Storage, coro: *Coroutine) void {
            coro_storage.free_list.prepend(&coro.list_node);
        }
    };

    const startup = struct {
        fn entry() callconv(.naked) void {
            switch (builtin.cpu.arch) {
                .x86_64 => switch (native_os) {
                    .windows => asm volatile (
                        \\ subq $40, %%rsp
                        \\ movq 40(%%rsp), %%rcx
                        \\ jmp %[call:P]
                        :
                        : [call] "X" (&call),
                    ),
                    else => asm volatile (
                        \\ subq $40, %%rsp
                        \\ movq 40(%%rsp), %%rdi
                        \\ jmp %[call:P]
                        :
                        : [call] "X" (&call),
                    ),
                },
                else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
            }
        }

        fn call(coro: *Coroutine) callconv(.c) noreturn {
            const rio = coro.rio;

            switch (coro.scheduling) {
                .awaitable => |awaitable| {
                    awaitable.start(coro.context_ptr, awaitable.result_ptr);
                },
                .grouped => |grouped| {
                    grouped.start(coro.context_ptr);

                    // Done. We can recycle self immediately.
                    grouped.group.remove(coro);
                    rio.coro_storage.recycle(coro);
                },
            }

            if (coro.awaiter) |awaiter|
                rio.schedule(awaiter);

            rio.yield(.exit);
            unreachable; // resumed an exited coroutine.
        }
    };
};

const vtable: Io.VTable = vtable: {
    var v = Io.failing.vtable.*;

    v.operate = operate;
    v.concurrent = concurrent;
    v.groupConcurrent = groupConcurrent;
    v.groupCancel = groupCancel;
    v.cancel = cancel;
    v.recancel = recancel;
    v.checkCancel = checkCancel;
    v.swapCancelProtection = swapCancelProtection;
    v.futexWait = futexWait;
    v.futexWaitUncancelable = futexWaitUncancelable;
    v.futexWake = futexWake;
    v.batchAwaitAsync = batchAwaitAsync;
    v.batchAwaitConcurrent = batchAwaitConcurrent;
    v.batchCancel = batchCancel;
    v.netBindIp = netBindIp;
    v.netSend = netSend;
    v.netListenIp = netListenIp;
    v.netClose = netClose;
    v.netAccept = netAccept;
    v.netRead = netRead;
    v.netWrite = netWrite;
    v.now = now;
    v.random = random;
    v.randomSecure = randomSecure;
    v.dirOpenFile = dirOpenFile;
    v.fileReadPositional = fileReadPositional;
    v.fileWritePositional = fileWritePositional;
    v.fileClose = fileClose;
    v.dirCreateDir = dirCreateDir;
    v.dirCreateDirPath = dirCreateDirPath;
    v.dirCreateFile = dirCreateFile;

    break :vtable v;
};

pub fn io(rio: *RemiellIo) Io {
    return .{ .userdata = rio, .vtable = &vtable };
}

fn futexWait(
    userdata: ?*anyopaque,
    ptr: *const u32,
    expected: u32,
    timeout: Io.Timeout,
) Io.Cancelable!void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    switch (timeout) {
        .none => {},
        // Timed waits are not supported right now, report as a spurious wakeup.
        .deadline, .duration => return,
    }

    if (rio.current_coro) |coro|
        try coro.cancelation.acknowledge();

    rio.yield(.{ .futex = .{
        .ptr = ptr,
        .expected = expected,
        .cancelation = .unblocked,
        .wait_list_node = .{},
    } });

    switch (rio.waitPoint().awaitee.futex.cancelation) {
        .blocked => unreachable,
        .unblocked => {},
        .canceled => {
            try rio.current_coro.?.cancelation.acknowledge();
            unreachable; // `acknowledge` must return `error.Canceled`
        },
    }
}

fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    rio.yield(.{ .futex = .{
        .ptr = ptr,
        .expected = expected,
        .cancelation = .blocked,
        .wait_list_node = .{},
    } });
}

fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    if (max_waiters == 0) return;

    var waiters: u32 = max_waiters;

    var next = rio.wait_list.first;
    while (next) |node| {
        next = node.next;

        const futex: *WaitPoint.Awaitee.Futex = @alignCast(@fieldParentPtr(
            "wait_list_node",
            node,
        ));

        if (futex.ptr != ptr) continue;

        const awaitee: *WaitPoint.Awaitee = @alignCast(@fieldParentPtr("futex", futex));
        const wait_point: *WaitPoint = @alignCast(@fieldParentPtr("awaitee", awaitee));

        rio.wait_list.remove(node);
        rio.schedule(wait_point);

        waiters = switch (waiters) {
            1 => break,
            else => waiters - 1,
        };
    }

    const point = rio.waitPoint();
    rio.schedule(point); // schedule self at last.
    rio.yield(.handoff);
}

fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    switch (operation) {
        .net_receive => |*o| {
            if (o.message_buffer.len == 0)
                return .{ .net_receive = .{ null, 0 } };

            const message = &o.message_buffer[0];

            const bytes_received = rio.syscall(.net_receive, .{
                .socket_handle = o.socket_handle,
                .from = &message.from,
                .buffer = o.data_buffer,
            }) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| return .{ .net_receive = .{ e, 0 } },
            };

            message.data = o.data_buffer[0..bytes_received];

            return .{ .net_receive = .{ null, 1 } };
        },

        .file_write_streaming => |*o| {
            const iovecs_capacity = if (Operation.FileWrite.vectored) 8 else 0;
            var iovecs_buffer: [iovecs_capacity]Impl.Vector(.@"const") = undefined;

            return .{
                .file_write_streaming = rio.fileWrite(
                    &iovecs_buffer,
                    o.file.handle,
                    .streaming,
                    o.header,
                    o.data,
                    o.splat,
                ) catch |err| switch (err) {
                    error.Unseekable => unreachable, // streaming
                    error.Canceled => |e| return e,
                    else => |e| e,
                },
            };
        },

        .file_read_streaming => |*o| {
            const iovecs_capacity = if (Operation.FileRead.vectored) 8 else 0;
            var iovecs_buffer: [iovecs_capacity]Impl.Vector(.@"var") = undefined;

            return .{
                .file_read_streaming = rio.fileRead(
                    &iovecs_buffer,
                    o.file.handle,
                    .streaming,
                    o.data,
                ) catch |err| switch (err) {
                    error.Unseekable => unreachable, // streaming
                    error.Canceled => |e| return e,
                    else => |e| e,
                },
            };
        },

        .device_io_control => unreachable, // Not implemented
    }
}

// Trailing:
// * [batch.storage.len]Operation.Storage.WithAwaiter
const BatchUserdata = extern struct {
    wait_point: ?*WaitPoint,
    completions_head: ?*anyopaque,
    completions_tail: ?*anyopaque,
    pending_count: u32,

    fn popCompletion(userdata: *BatchUserdata) ?*Operation.Storage.WithAwaiter {
        const head: *DoublyLinkedList.Node = @ptrCast(@alignCast(userdata.completions_head orelse
            return null));

        userdata.completions_head = head.next;

        if (userdata.completions_head == null)
            userdata.completions_tail = null;

        if (head.prev) |prev|
            prev.next = head.next
        else
            userdata.completions_head = head.next;

        if (head.next) |next|
            next.prev = head.prev
        else
            userdata.completions_tail = head.prev;

        const completion: *Operation.Storage.Completion = @alignCast(@fieldParentPtr("node", head));
        return completion.parentPtr(Operation.Storage.WithAwaiter, "storage");
    }

    fn appendCompletion(userdata: *BatchUserdata, node: *DoublyLinkedList.Node) void {
        if (userdata.completions_tail) |tail_ptr| {
            const tail: *DoublyLinkedList.Node = @ptrCast(@alignCast(tail_ptr));
            tail.next = node;
            node.prev = tail;
            node.next = null;
            userdata.completions_tail = node;
        } else { // empty
            userdata.completions_tail = node;
            userdata.completions_head = node;
            node.prev = null;
            node.next = null;
        }
    }

    inline fn operations(userdata: *BatchUserdata) [*]Operation.Storage.WithAwaiter {
        return @ptrFromInt(std.mem.alignForward(
            usize,
            @intFromPtr(userdata) + @sizeOf(BatchUserdata),
            @alignOf(Operation.Storage.WithAwaiter),
        ));
    }

    fn allocationSize(operations_count: usize) usize {
        const operations_base = std.mem.alignForward(
            usize,
            @sizeOf(BatchUserdata),
            @alignOf(Operation.Storage.WithAwaiter),
        );

        const operations_size = std.mem.alignForward(
            usize,
            @sizeOf(Operation.Storage.WithAwaiter),
            @alignOf(Operation.Storage.WithAwaiter),
        ) * operations_count;

        return operations_base + operations_size;
    }

    fn create(gpa: Allocator, operations_count: usize) Allocator.Error!*BatchUserdata {
        const batch_userdata: *BatchUserdata = @ptrCast(try gpa.alignedAlloc(
            u8,
            .of(BatchUserdata),
            allocationSize(operations_count),
        ));

        batch_userdata.wait_point = null;
        batch_userdata.pending_count = 0;
        batch_userdata.completions_head = null;
        batch_userdata.completions_tail = null;

        return batch_userdata;
    }

    fn destroy(userdata: *BatchUserdata, gpa: Allocator, operations_count: usize) void {
        const bytes = @as(
            [*]align(@alignOf(BatchUserdata)) u8,
            @ptrCast(@alignCast(userdata)),
        )[0..allocationSize(operations_count)];

        gpa.free(bytes);
    }

    fn indexOf(userdata: *BatchUserdata, item: *Operation.Storage.WithAwaiter) usize {
        const list = userdata.operations();
        return @divExact(@intFromPtr(item) - @intFromPtr(list), std.mem.alignForward(
            usize,
            @sizeOf(Operation.Storage.WithAwaiter),
            @alignOf(Operation.Storage.WithAwaiter),
        ));
    }

    const NetReceive = extern struct {
        message_buffer: [*]Io.net.IncomingMessage,
        data_buffer: [*]u8,

        const TypeErased = Io.Operation.Storage.Pending.Userdata;

        comptime {
            debug.assert(@sizeOf(NetReceive) <= @sizeOf(TypeErased));
        }

        inline fn fromErased(type_erased: *TypeErased) *NetReceive {
            return @ptrCast(type_erased);
        }

        fn init(userdata: *NetReceive, operation: *const Io.Operation.NetReceive) void {
            userdata.message_buffer = operation.message_buffer.ptr;
            userdata.data_buffer = operation.data_buffer.ptr;
        }
    };
};

fn batchAwaitAsync(userdata: ?*anyopaque, batch: *Io.Batch) Io.Cancelable!void {
    batchAwaitConcurrent(userdata, batch, .none) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.Timeout => unreachable,
        error.ConcurrencyUnavailable => {
            // If concurrency is not available, perform one operation and return.

            if (batch.submitted.head == .none)
                return;

            const index = batch.submitted.head;

            const submission = &batch.storage[index.toIndex()].submission;
            const result = try operate(userdata, submission.operation);

            if (batch.submitted.head == batch.submitted.tail)
                batch.submitted = .{ .head = .none, .tail = .none }
            else
                batch.submitted.head = submission.node.next;

            batch.storage[index.toIndex()] = .{ .completion = .{
                .node = .{ .next = batch.completed.head },
                .result = result,
            } };

            switch (batch.completed.tail) {
                .none => batch.completed = .{ .head = index, .tail = index },
                _ => |tail| {
                    batch.completed.tail = index;
                    batch.storage[tail.toIndex()].completion.node.next = index;
                },
            }

            batch.completed.head = index;
        },
    };
}

fn batchAwaitConcurrent(
    userdata: ?*anyopaque,
    batch: *Io.Batch,
    timeout: Io.Timeout,
) Io.Batch.AwaitConcurrentError!void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    const wait_point = rio.waitPoint();

    switch (timeout) {
        .none => {},
        .deadline, .duration => return error.ConcurrencyUnavailable, // TODO: submit `Operation.Sleep`.
    }

    if (rio.current_coro) |coro|
        try coro.cancelation.acknowledge();

    const batch_userdata: *BatchUserdata = if (batch.userdata) |type_erased| existing: {
        const batch_userdata: *BatchUserdata = @ptrCast(@alignCast(type_erased));
        var any_completed: bool = false;

        while (batch_userdata.popCompletion()) |with_awaiter| {
            any_completed = true;
            batch_userdata.pending_count -= 1;

            batchPutCompletion(batch, batch_userdata, &with_awaiter.storage.completion);
        }

        if (any_completed) return;

        break :existing batch_userdata;
    } else create: {
        const batch_userdata = BatchUserdata.create(rio.gpa, batch.storage.len) catch
            return error.ConcurrencyUnavailable;

        batch.userdata = batch_userdata;
        break :create batch_userdata;
    };

    const batched_list = batch_userdata.operations()[0..batch.storage.len];

    var next = batch.submitted.head;
    while (next != .none) {
        const index = next.toIndex();
        const storage = &batch.storage[index];

        next = storage.submission.node.next;

        switch (storage.submission.operation) {
            .file_read_streaming,
            .file_write_streaming,
            .device_io_control,
            => return error.ConcurrencyUnavailable, // TODO

            .net_receive => |net_receive| {
                const message = &net_receive.message_buffer[0];

                batched_list[index] = .{
                    .awaiter = .{ .batch = batch_userdata },
                    .storage = .init(.{ .net_receive = .{
                        .socket_handle = net_receive.socket_handle,
                        .from = &message.from,
                        .buffer = net_receive.data_buffer,
                    } }),
                };

                rio.impl.submissions.append(&batched_list[index].storage.submission.node);

                storage.* = .{
                    .pending = .{
                        .node = .{ .prev = batch.pending.tail, .next = .none },
                        .tag = .net_receive,
                        .userdata = undefined,
                    },
                };

                const operation_userdata: *BatchUserdata.NetReceive = .fromErased(&storage.pending.userdata);
                operation_userdata.init(&net_receive);
            },
        }

        switch (batch.pending.tail) {
            .none => batch.pending.head = @enumFromInt(index),
            _ => |tail| batch.storage[tail.toIndex()].pending.node.next = @enumFromInt(index),
        }

        batch.storage[index].pending.node.prev = batch.pending.tail;
        batch.submitted.head = next;

        batch.pending.tail = @enumFromInt(index);
        batch_userdata.pending_count += 1;
    }

    batch.submitted.tail = .none;

    if (batch_userdata.pending_count == 0)
        return;

    wait_point.awaitee = .{
        .operation = .{
            .outstanding = batch_userdata.pending_count,
            .status = .waiting_for_one_or_more,
        },
    };

    batch_userdata.wait_point = wait_point;
    rio.yield(.wait_for_io);
    batch_userdata.wait_point = null;

    if (batch_userdata.completions_head == null) {
        // Must be due to cancelation.
        try rio.current_coro.?.cancelation.acknowledge();
        unreachable; // `acknowledge` must return `error.Canceled`
    }

    while (batch_userdata.popCompletion()) |with_awaiter| {
        batch_userdata.pending_count -= 1;
        batchPutCompletion(batch, batch_userdata, &with_awaiter.storage.completion);
    }
}

fn batchCancel(userdata: ?*anyopaque, batch: *Io.Batch) void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    const batch_userdata: *BatchUserdata = @ptrCast(@alignCast(batch.userdata orelse return));

    if (batch_userdata.pending_count != 0) {
        const maybe_coro = rio.current_coro;
        const wait_point = rio.waitPoint();
        batch_userdata.wait_point = wait_point;

        const batched_list = batch_userdata.operations()[0..batch.storage.len];

        const old_cancelation_protection: Io.CancelProtection = if (maybe_coro) |coro|
            coro.cancelation.swapProtection(.blocked)
        else
            undefined;

        defer if (maybe_coro) |coro| {
            _ = coro.cancelation.swapProtection(old_cancelation_protection);
        };

        var next = batch.pending.head;
        var remaining = batch_userdata.pending_count;

        while (remaining != 0) {
            var cancelations: [16]Operation.Storage.WithAwaiter = undefined;
            const oneshot_size = @min(cancelations.len, batch_userdata.pending_count);
            remaining -= oneshot_size;

            for (cancelations[0..oneshot_size]) |*cancelation| {
                const index = next.toIndex();
                next = batch.storage[index].pending.node.next;

                cancelation.* = .{
                    .awaiter = .{ .batch = batch_userdata },
                    .storage = .init(.{ .cancel = .{ .operation = &batched_list[index].storage } }),
                };

                rio.impl.submissions.append(&cancelation.storage.submission.node);
            }

            var unacknowledged = oneshot_size;

            // Wait for cancelation acknowledgements.
            // During this time, regular operation completions may arrive as well.
            while (unacknowledged != 0) {
                wait_point.awaitee = .{ .operation = .{
                    .outstanding = batch_userdata.pending_count + unacknowledged,
                    .status = .waiting_for_one_or_more,
                } };

                rio.yield(.wait_for_io);

                while (batch_userdata.popCompletion()) |with_awaiter| {
                    switch (with_awaiter.storage.completion.result) {
                        .cancel => unacknowledged -= 1,
                        else => {
                            batch_userdata.pending_count -= 1;
                            batchPutCompletion(batch, batch_userdata, &with_awaiter.storage.completion);
                        },
                    }
                }
            }
        }

        // All cancelation requests are acknowledged. Remaining operations may be still in progress.
        if (batch_userdata.pending_count != 0) {
            wait_point.awaitee = .{ .operation = .{
                .outstanding = batch_userdata.pending_count,
                .status = .waiting_for_all,
            } };

            rio.yield(.wait_for_io);

            while (batch_userdata.popCompletion()) |with_awaiter| {
                switch (with_awaiter.storage.completion.result) {
                    .cancel => unreachable, // cancel requests are already acknowledged.
                    else => {
                        batch_userdata.pending_count -= 1;
                        batchPutCompletion(batch, batch_userdata, &with_awaiter.storage.completion);
                    },
                }
            }
        }
    }

    debug.assert(batch_userdata.pending_count == 0);
    batch_userdata.destroy(rio.gpa, batch.storage.len);
    batch.userdata = null;
}

/// Removes from `batch.pending` and puts into `batch.completed`.
fn batchPutCompletion(
    batch: *Io.Batch,
    batch_userdata: *BatchUserdata,
    completion: *Operation.Storage.Completion,
) void {
    const operation = completion.parentPtr(Operation.Storage.WithAwaiter, "storage");
    const index = batch_userdata.indexOf(operation);

    const pending = &batch.storage[index].pending;

    switch (pending.node.prev) {
        .none => batch.pending.head = pending.node.next,
        else => |prev| batch.storage[prev.toIndex()].pending.node.next = pending.node.next,
    }

    switch (pending.node.next) {
        .none => batch.pending.tail = pending.node.prev,
        else => |next| batch.storage[next.toIndex()].pending.node.prev = pending.node.prev,
    }

    switch (completion.result) {
        .cancel => unreachable,
        .net_receive => |result| {
            const operation_userdata: *BatchUserdata.NetReceive = .fromErased(&pending.userdata);

            batch.storage[index] = .{ .completion = .{
                .node = .{ .next = batch.completed.head },
                .result = .{ .net_receive = if (result) |n_received| result: {
                    const message = &operation_userdata.message_buffer[0];
                    message.data = operation_userdata.data_buffer[0..n_received];

                    break :result .{ null, 1 };
                } else |err| switch (err) {
                    error.Canceled => return,
                    else => |e| .{ e, 0 },
                } },
            } };

            batch.completed.head = @enumFromInt(index);
        },
        else => unreachable,
    }
}

fn concurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    const coro = rio.coro_storage.allocate(rio.arena.allocator()) catch |err| switch (err) {
        error.OutOfMemory, error.LimitExceeded => return error.ConcurrencyUnavailable,
    };

    errdefer rio.coro_storage.recycle(coro);

    const buf_aligned = result_alignment.forward(@intFromPtr(coro.buffer.ptr));
    const owned_context_ptr: [*]u8 = @ptrFromInt(context_alignment.forward(buf_aligned + result_len));

    // The bare minimum of buffer size. Of course, we'll also need some for the stack itself.
    const aligned_end = @intFromPtr(owned_context_ptr) + context.len;

    // This is where actual coroutine stack starts.
    const stack_start: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, aligned_end, 16));
    const stack_pointer: [*]u8 = @ptrFromInt(std.mem.alignBackward(
        usize,
        @intFromPtr(coro.buffer.ptr) + coro.buffer.len - 8,
        16,
    ));

    if (@intFromPtr(stack_start) - @intFromPtr(coro.buffer.ptr) > coro.buffer.len)
        return error.ConcurrencyUnavailable;

    errdefer comptime unreachable;

    coro.scheduling = .{ .awaitable = .{
        .start = start,
        .result_ptr = @ptrFromInt(buf_aligned),
    } };

    coro.context_ptr = owned_context_ptr;
    coro.cancelation = .init;
    coro.rio = rio;
    coro.awaiter = null;

    coro.wait_point = .{
        .awaitee = .none,
        .wakeup_queue_node = .{},
        .context = .{
            .rsp = @intFromPtr(stack_pointer),
            .rip = @intFromPtr(&Coroutine.startup.entry),
            .rbp = 0,
        },
    };

    @memcpy(owned_context_ptr[0..context.len], context);
    @memcpy(stack_pointer[0..8], std.mem.asBytes(&coro));

    rio.schedule(&coro.wait_point);
    return @ptrCast(coro);
}

fn cancel(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    _ = result_alignment;

    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    const coroutine: *Coroutine = @ptrCast(@alignCast(any_future));
    rio.cancelAndWait(coroutine);

    @memcpy(result, @as([*]u8, @ptrCast(coroutine.scheduling.awaitable.result_ptr))[0..result.len]);
    rio.coro_storage.recycle(coroutine);
}

/// Puts a cancelation request on `coro` and waits until it finishes.
fn cancelAndWait(rio: *RemiellIo, coro: *Coroutine) void {
    if (coro.hasExited()) return; // There's nothing to do

    coro.awaiter = rio.waitPoint();
    coro.cancelation.request();

    if (coro.cancelation.protection == .unblocked) switch (coro.wait_point.awaitee) {
        .operation => |o| switch (o.outstanding) {
            // Nothing to do. The task is already scheduled since its operation is complete.
            0 => {},
            else => rio.schedule(&coro.wait_point),
        },

        // TODO: should it propagate cancelation request?
        .idle, .shutdown, .none, .coroutine => {},

        .futex => |*futex| switch (futex.cancelation) {
            .blocked => {},
            .unblocked => {
                futex.cancelation = .canceled;

                const awaitee: *WaitPoint.Awaitee = @alignCast(@fieldParentPtr("futex", futex));
                const wait_point: *WaitPoint = @alignCast(@fieldParentPtr("awaitee", awaitee));

                rio.wait_list.remove(&futex.wait_list_node);
                rio.schedule(wait_point);
            },
            .canceled => unreachable, // always a race condition
        },
    };

    rio.yield(.{ .join = .{ .awaitee = coro } });
}

fn groupConcurrent(
    userdata: ?*anyopaque,
    g: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (*const anyopaque) void,
) Io.ConcurrentError!void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    const group: Group = .{ .ptr = g };

    const coro = rio.coro_storage.allocate(rio.arena.allocator()) catch |err| switch (err) {
        error.OutOfMemory, error.LimitExceeded => return error.ConcurrencyUnavailable,
    };

    errdefer rio.coro_storage.recycle(coro);

    const owned_context_ptr: [*]u8 = @ptrFromInt(context_alignment.forward(@intFromPtr(coro.buffer.ptr)));

    // The bare minimum of buffer size. Of course, we'll also need some for the stack itself.
    const aligned_end = @intFromPtr(owned_context_ptr) + context.len;

    // This is where actual coroutine stack starts.
    const stack_start: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, aligned_end, 16));
    const stack_pointer: [*]u8 = @ptrFromInt(std.mem.alignBackward(
        usize,
        @intFromPtr(coro.buffer.ptr) + coro.buffer.len - 8,
        16,
    ));

    if (@intFromPtr(stack_start) - @intFromPtr(coro.buffer.ptr) > coro.buffer.len)
        return error.ConcurrencyUnavailable;

    coro.scheduling = .{ .grouped = .{
        .start = start,
        .group = group,
    } };

    coro.context_ptr = owned_context_ptr;
    coro.cancelation = .init;
    coro.rio = rio;
    coro.awaiter = null;

    coro.wait_point = .{
        .awaitee = .none,
        .wakeup_queue_node = .{},
        .context = .{
            .rsp = @intFromPtr(stack_pointer),
            .rip = @intFromPtr(&Coroutine.startup.entry),
            .rbp = 0,
        },
    };

    @memcpy(owned_context_ptr[0..context.len], context);
    @memcpy(stack_pointer[0..8], std.mem.asBytes(&coro));

    rio.schedule(&coro.wait_point);
    group.append(coro);
}

fn groupCancel(
    userdata: ?*anyopaque,
    g: *Io.Group,
    _: *anyopaque,
) void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    const group: Group = .{ .ptr = g };

    while (group.peek()) |coro|
        rio.cancelAndWait(coro);
}

fn recancel(userdata: ?*anyopaque) void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    const coro = rio.current_coro orelse
        // This is unreachable because first of all main frame cannot be canceled,
        // second of all, recancel() may only be called to re-arm cancelation request
        unreachable;

    switch (coro.cancelation.status) {
        .none, .requested => unreachable,
        .acknowledged => coro.cancelation.status = .requested,
    }
}

fn fileClose(userdata: ?*anyopaque, files: []const Io.File) void {
    // Only linux can batch `close(2)`.
    if (native_os != .linux) {
        for (files) |file| switch (native_os) {
            .windows => _ = Impl.NtClose(file.handle),
            else => _ = posix.system.close(file.handle),
        };

        return;
    }

    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    rio.closeMany(Io.File, files);
}

fn netClose(userdata: ?*anyopaque, handles: []const net.Socket.Handle) void {
    // Only linux can batch `close(2)`.
    if (native_os != .linux) {
        for (handles) |handle| switch (native_os) {
            .windows => _ = Impl.closesocket(handle),
            else => _ = posix.system.close(handle),
        };

        return;
    }

    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    rio.closeMany(net.Socket.Handle, handles);
}

fn closeMany(rio: *RemiellIo, comptime T: type, list: []const T) void {
    const maybe_coro = rio.current_coro;
    const wp = rio.waitPoint();

    // resource deallocation must succeed.
    const old_cancelation_protection: Io.CancelProtection = if (maybe_coro) |coro|
        coro.cancelation.swapProtection(.blocked)
    else
        undefined;

    defer if (maybe_coro) |coro| {
        _ = coro.cancelation.swapProtection(old_cancelation_protection);
    };

    // Can batch up to this amount of `close` operations within a single syscall.
    var operations: [16]Operation.Storage.WithAwaiter = undefined;
    var cursor = list;

    while (cursor.len != 0) {
        const oneshot_size = @min(operations.len, cursor.len);
        defer cursor = cursor[oneshot_size..];

        for (operations[0..oneshot_size], cursor[0..oneshot_size]) |*op, entry| {
            op.* = .{ .awaiter = .{ .synchronous = wp }, .storage = .init(
                .{ .close = .{
                    .handle = switch (T) {
                        net.Socket.Handle => entry,
                        Io.File => entry.handle,
                        else => comptime unreachable,
                    },
                } },
            ) };

            rio.impl.submissions.append(&op.storage.submission.node);
        }

        wp.awaitee = .{ .operation = .{
            .outstanding = @intCast(oneshot_size),
            .status = .waiting_for_all,
        } };

        rio.yield(.wait_for_io);
        debug.assert(wp.awaitee.operation.outstanding == 0);
    }
}

fn netBindIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.BindOptions,
) net.IpAddress.BindError!net.Socket {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    return rio.impl.netBind(address, options, false);
}

fn netSend(userdata: ?*anyopaque, socket_handle: net.Socket.Handle, messages: []net.OutgoingMessage, flags: net.SendFlags) struct { ?net.Socket.SendError, usize } {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    for (messages, 0..) |*message, sent|
        rio.netSendOne(socket_handle, message, flags) catch |err|
            return .{ err, sent };

    return .{ null, messages.len };
}

fn netSendOne(
    rio: *RemiellIo,
    socket_handle: net.Socket.Handle,
    message: *net.OutgoingMessage,
    flags: net.SendFlags,
) net.Socket.SendError!void {
    _ = flags;

    if (rio.syscall(.net_send, .{
        .socket_handle = socket_handle,
        .to = message.address,
        .buffer = message.data_ptr[0..message.data_len],
    })) |n_sent| {
        message.data_len = n_sent;
    } else |err| {
        message.data_len = 0;
        return err;
    }
}

fn netListenIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.ListenOptions,
) net.IpAddress.ListenError!net.Socket {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    return rio.impl.netListen(address, options);
}

fn netAccept(
    userdata: ?*anyopaque,
    listener: net.Socket.Handle,
    options: net.Server.AcceptOptions,
) net.Server.AcceptError!net.Socket {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    _ = options;

    return rio.syscall(.net_accept, .{
        .listener_handle = listener,
    });
}

fn netRead(
    userdata: ?*anyopaque,
    socket: net.Socket.Handle,
    data: [][]u8,
) net.Stream.Reader.Error!usize {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    return rio.syscall(.net_read, .{
        .stream_handle = socket,
        .buffer = data[0],
    });
}

fn netWrite(
    userdata: ?*anyopaque,
    socket: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) net.Stream.Writer.Error!usize {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    var iovecs: [8]Impl.Vector(.@"const") = undefined;
    var iovecs_count: usize = 0;

    addVector(.@"const", &iovecs, &iovecs_count, header);
    for (data[0 .. data.len - 1]) |bytes| addVector(.@"const", &iovecs, &iovecs_count, bytes);
    const pattern = data[data.len - 1];

    var splat_backup_buffer: [64]u8 = undefined;
    if (iovecs.len - iovecs_count != 0) switch (splat) {
        0 => {},
        1 => addVector(.@"const", &iovecs, &iovecs_count, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                const splat_buffer = &splat_backup_buffer;
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                addVector(.@"const", &iovecs, &iovecs_count, buf);
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and iovecs.len - iovecs_count != 0) {
                    debug.assert(buf.len == splat_buffer.len);
                    addVector(.@"const", &iovecs, &iovecs_count, splat_buffer);
                    remaining_splat -= splat_buffer.len;
                }
                addVector(.@"const", &iovecs, &iovecs_count, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
            },
            else => for (0..@min(splat, iovecs.len - iovecs_count)) |_| {
                addVector(.@"const", &iovecs, &iovecs_count, pattern);
            },
        },
    };

    return rio.syscall(.net_write, .{
        .stream_handle = socket,
        .data = iovecs[0..iovecs_count],
    });
}

fn random(userdata: ?*anyopaque, buffer: []u8) void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    if (rio.csprng == null) {
        @branchHint(.unlikely);
        var seed: [DefaultCsprng.secret_seed_length]u8 = undefined;

        randomSecureFill(&seed) catch {
            // Fallback seed
            std.mem.writeInt(u64, buffer[0..8], @intCast(Impl.getTime(.boot).toMilliseconds()), .native);
            std.mem.writeInt(usize, buffer[8..][0..@sizeOf(usize)], @intFromPtr(userdata), .native);
        };

        rio.csprng = .init(seed);
    }

    rio.csprng.?.fill(buffer);
}

fn randomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    _ = rio;

    try randomSecureFill(buffer);
}

fn randomSecureFill(buffer: []u8) !void {
    // Right now it's synchronous and not cancelable.
    switch (native_os) {
        .linux => fillFromDevUrandom(buffer) catch
            return error.EntropyUnavailable,
        .windows => fillFromDeviceCng(buffer) catch
            return error.EntropyUnavailable,
        else => return error.EntropyUnavailable, // Not implemented.
    }
}

fn fillFromDevUrandom(buffer: []u8) !void {
    const open_rc = linux.open("/dev/urandom", .{}, 0);
    const fd: linux.fd_t = switch (linux.errno(open_rc)) {
        .SUCCESS => @intCast(open_rc),
        else => return error.OpenFailed,
    };

    defer _ = linux.close(fd);

    var unfilled = buffer;
    while (unfilled.len != 0) {
        const read_rc = linux.read(fd, unfilled.ptr, unfilled.len);
        switch (linux.errno(read_rc)) {
            .SUCCESS => unfilled = unfilled[read_rc..],
            else => return error.ReadFailed,
        }
    }
}

fn fillFromDeviceCng(buffer: []u8) !void {
    var handle: windows.HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    switch (windows.ntdll.NtOpenFile(
        &handle,
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .FILE = .{ .READ_DATA = true } },
        },
        &.{ .ObjectName = @constCast(&windows.UNICODE_STRING.init(
            &.{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'C', 'N', 'G' },
        )) },
        &iosb,
        .VALID_FLAGS,
        .{ .IO = .SYNCHRONOUS_NONALERT },
    )) {
        .SUCCESS => {},
        else => return error.OpenFailed,
    }

    defer _ = windows.ntdll.NtClose(handle);

    var unfilled = buffer;
    while (unfilled.len != 0) switch (windows.ntdll.NtDeviceIoControlFile(
        handle,
        null,
        null,
        null,
        &iosb,
        windows.IOCTL.KSEC.GEN_RANDOM,
        null,
        0,
        unfilled.ptr,
        @truncate(unfilled.len),
    )) {
        .SUCCESS => unfilled = unfilled[@as(u32, @truncate(unfilled.len))..],
        else => return error.IoctlFailed,
    };
}

fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    if (rio.current_coro) |coro|
        try coro.cancelation.acknowledge();
}

fn swapCancelProtection(userdata: ?*anyopaque, protection: Io.CancelProtection) Io.CancelProtection {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    return if (rio.current_coro) |coro|
        coro.cancelation.swapProtection(protection)
    else
        .unblocked;
}

fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    _ = userdata;

    return switch (clock) {
        .real, .awake, .boot, .cpu_process => Impl.getTime(clock),
        .cpu_thread => .zero, // TODO: this has to respect coroutines
    };
}

fn dirOpenFile(
    userdata: ?*anyopaque,
    dir: Io.Dir,
    sub_path: []const u8,
    options: Io.Dir.OpenFileOptions,
) Io.File.OpenError!Io.File {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    var path_buffer: Impl.PathBuffer = undefined;
    try path_buffer.initPinned(dir.handle, sub_path);

    const handle = try rio.syscall(.dir_open_file, .{
        .dir_handle = dir.handle,
        .sub_path = &path_buffer,
        .options = options,
    });

    return .{
        .handle = handle,
        .flags = .{ .nonblocking = false },
    };
}

fn fileReadPositional(
    userdata: ?*anyopaque,
    file: Io.File,
    data: []const []u8,
    offset: u64,
) Io.File.ReadPositionalError!usize {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    const iovecs_capacity = if (Operation.FileRead.vectored) 8 else 0;
    var iovecs_buffer: [iovecs_capacity]Impl.Vector(.@"var") = undefined;

    return rio.fileRead(
        &iovecs_buffer,
        file.handle,
        .{ .positional = offset },
        data,
    ) catch |err| switch (err) {
        error.ConnectionResetByPeer,
        error.SocketUnconnected,
        error.EndOfStream,
        => unreachable, // positional
        else => |e| e,
    };
}

fn dirCreateDir(
    userdata: ?*anyopaque,
    dir: Io.Dir,
    sub_path: []const u8,
    permissions: Io.Dir.Permissions,
) Io.Dir.CreateDirError!void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    var path_buffer: Impl.PathBuffer = undefined;
    try path_buffer.initPinned(dir.handle, sub_path);

    return rio.syscall(.create_dir, .{
        .at = dir.handle,
        .sub_path = &path_buffer,
        .permissions = permissions,
    });
}

fn dirCreateDirPath(
    userdata: ?*anyopaque,
    dir: Io.Dir,
    sub_path: []const u8,
    permissions: Io.Dir.Permissions,
) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
    var it = Io.Dir.path.componentIterator(sub_path);
    var status: Io.Dir.CreatePathStatus = .existed;
    var component = it.last() orelse return error.BadPathName;

    while (true) {
        if (dirCreateDir(userdata, dir, component.path, permissions)) |_| {
            status = .created;
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            error.FileNotFound => |e| {
                component = it.previous() orelse return e;
                continue;
            },
            else => |e| return e,
        }
        component = it.next() orelse return status;
    }
}

fn dirCreateFile(
    userdata: ?*anyopaque,
    dir: Io.Dir,
    sub_path: []const u8,
    options: Io.Dir.CreateFileOptions,
) Io.File.OpenError!Io.File {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    var path_buffer: Impl.PathBuffer = undefined;
    try path_buffer.initPinned(dir.handle, sub_path);

    const handle = try rio.syscall(.dir_create_file, .{
        .at = dir.handle,
        .sub_path = &path_buffer,
        .options = options,
    });

    return .{
        .handle = handle,
        .flags = .{ .nonblocking = false },
    };
}

fn fileWritePositional(
    userdata: ?*anyopaque,
    file: Io.File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) Io.File.WritePositionalError!usize {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    const iovecs_capacity = if (Operation.FileWrite.vectored) 8 else 0;
    var iovecs_buffer: [iovecs_capacity]Impl.Vector(.@"const") = undefined;

    return try rio.fileWrite(&iovecs_buffer, file.handle, .{ .positional = offset }, header, data, splat);
}

fn fileWrite(
    rio: *RemiellIo,
    iovecs_buffer: []Impl.Vector(.@"const"),
    file: Io.File.Handle,
    mode: FileOperationMode,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) Operation.FileWrite.Result {
    var iovecs_count: usize = 0;

    if (Operation.FileWrite.vectored) {
        addVector(.@"const", iovecs_buffer, &iovecs_count, header);

        for (data[0 .. data.len - 1]) |buf|
            addVector(.@"const", iovecs_buffer, &iovecs_count, buf);

        const pattern = data[data.len - 1];
        for (0..splat) |_|
            addVector(.@"const", iovecs_buffer, &iovecs_count, pattern);

        if (iovecs_count == 0)
            return 0;

        return rio.syscall(.file_write, .{
            .file_handle = file,
            .mode = mode,
            .data = iovecs_buffer[0..iovecs_count],
        });
    } else {
        const buffer: []const u8 = buffer: {
            if (header.len != 0) break :buffer header;

            for (data[0 .. data.len - 1]) |buf| if (buf.len != 0)
                break :buffer buf;

            const pattern = data[data.len - 1];
            if (pattern.len == 0 or splat == 0)
                return 0;

            break :buffer data[data.len - 1];
        };

        return rio.syscall(.file_write, .{
            .file_handle = file,
            .mode = mode,
            .data = buffer,
        });
    }
}

fn fileRead(
    rio: *RemiellIo,
    iovecs_buffer: []Impl.Vector(.@"var"),
    file: Io.File.Handle,
    mode: FileOperationMode,
    data: []const []u8,
) Operation.FileRead.Result {
    var iovecs_count: usize = 0;

    if (Operation.FileRead.vectored) {
        for (data) |buf| if (buf.len != 0)
            addVector(.@"var", iovecs_buffer, &iovecs_count, buf);
    }

    return rio.syscall(.file_read, .{
        .file_handle = file,
        .mode = mode,
        .data = if (Operation.FileRead.vectored)
            iovecs_buffer[0..iovecs_count]
        else
            data[0],
    });
}

fn waitPoint(rio: *RemiellIo) *WaitPoint {
    const current = rio.current_coro orelse return &rio.naked_wait;
    return &current.wait_point;
}

const YieldReason = union(enum) {
    const Join = struct {
        awaitee: *Coroutine,
    };

    /// The coroutine has finished its execution.
    exit: void,

    /// The coroutine wants to wait for an I/O operation to complete.
    wait_for_io: void,

    /// The coroutine wants to block until awaitee exits.
    join: Join,

    /// The coroutine wants to block until shutdown sequence is initiated.
    wait_for_shutdown: void,

    /// The coroutine wants to wait on a futex.
    futex: WaitPoint.Awaitee.Futex,

    /// The coroutine is cooperatively handing CPU time to other coroutines.
    handoff: void,
};

/// Performs one synchronous (in relation to coroutine) I/O operation.
fn syscall(
    rio: *RemiellIo,
    comptime op: Operation.Tag,
    param: @FieldType(Operation, @tagName(op)),
) @TypeOf(param).Result {
    if (rio.current_coro) |current_coro|
        try current_coro.cancelation.acknowledge();

    const wp = rio.waitPoint();

    var operation: Operation.Storage.WithAwaiter = .{
        .awaiter = .{ .synchronous = wp },
        .storage = .init(@unionInit(Operation, @tagName(op), param)),
    };

    var cancelation: Operation.Storage.WithAwaiter = .{
        .awaiter = .{ .synchronous = wp },
        .storage = .init(.{ .cancel = .{ .operation = &operation.storage } }),
    };

    wp.awaitee = .{ .operation = .{
        .outstanding = 1,
        .status = .waiting_for_all,
    } };

    const wait = &wp.awaitee.operation;

    rio.impl.submissions.append(&operation.storage.submission.node);

    rio.yield(.wait_for_io);

    if (wait.outstanding == 0) {
        // Operation completed normally, we're done here.
        return @field(
            operation.storage.completion.result,
            @tagName(op),
        ) catch |err| switch (err) {
            error.Canceled => unreachable, // nobody asked for it
            else => |e| e,
        };
    }

    // Otherwise this is an early wakeup due to the cancelation.
    debug.assert(wait.outstanding == 1); // always a race condition

    wait.* = .{
        .outstanding = 2,
        .status = .waiting_for_all,
    };

    rio.impl.submissions.append(&cancelation.storage.submission.node);
    rio.yield(.wait_for_io);

    // Now we should be switched to only because outstanding ops are done.
    debug.assert(wait.outstanding == 0); // always a race condition

    return @field(
        operation.storage.completion.result,
        @tagName(op),
    ) catch |err| switch (err) {
        error.Canceled => {
            // The operation was successfully canceled, acknowledge the task-level cancelation.
            try rio.current_coro.?.cancelation.acknowledge();
            unreachable; // `acknowledge` must return `error.Canceled`
        },
        else => |e| e,
    };
}

/// Yield the execution.
/// This may result in the following:
/// * Switching to another coroutine that is in `wakeup_queue`.
/// * Blocking in `impl.await` until one or more I/O operations complete.
fn yield(rio: *RemiellIo, reason: YieldReason) void {
    const enter_wait_point = rio.waitPoint();

    switch (reason) {
        .exit => enter_wait_point.awaitee = .idle,
        .wait_for_shutdown => enter_wait_point.awaitee = .shutdown,
        .wait_for_io => debug.assert(.operation == std.meta.activeTag(enter_wait_point.awaitee)),
        .join => |join| enter_wait_point.awaitee = .{ .coroutine = join.awaitee },
        .futex => |futex| {
            enter_wait_point.awaitee = .{ .futex = futex };
            rio.wait_list.append(&enter_wait_point.awaitee.futex.wait_list_node);
        },
        .handoff => {},
    }

    wait_loop: while (true) {
        if (rio.shutdown == .pending) {
            rio.shutdown = .acknowledged;
            rio.schedule(rio.shutdown_wait_point);
        }

        if (rio.wakeup_queue.popFirst()) |node| {
            const wakeup_wait_point: *WaitPoint = @fieldParentPtr("wakeup_queue_node", node);

            if (!rio.wakeup(wakeup_wait_point))
                break :wait_loop;

            break :wait_loop;
        }

        _ = rio.impl.await() catch |err| if (is_debug)
            debug.panic("rio.impl.await: {t}", .{err})
        else
            abort();

        while (rio.impl.completions.popFirst()) |node| {
            const completion: *Operation.Storage.Completion = @alignCast(@fieldParentPtr("node", node));
            const storage = completion.parentPtr(Operation.Storage.WithAwaiter, "storage");

            const point = switch (storage.awaiter) {
                .synchronous => |wait_point| wait_point,
                .batch => |batch_userdata| batch: {
                    batch_userdata.appendCompletion(&completion.node);
                    break :batch batch_userdata.wait_point orelse continue;
                },
            };

            const wait = &point.awaitee.operation;
            wait.outstanding -= 1;

            switch (wait.status) {
                .scheduled => {}, // already
                .waiting_for_one_or_more => {
                    wait.status = .scheduled;
                    rio.schedule(point);
                },
                .waiting_for_all => if (wait.outstanding == 0) {
                    wait.status = .scheduled;
                    rio.schedule(point);
                },
            }
        }
    }
}

fn schedule(rio: *RemiellIo, wait_point: *WaitPoint) void {
    rio.wakeup_queue.append(&wait_point.wakeup_queue_node);
}

/// Returns `false` if `wake_wait_point` is the current one.
/// In which case, the caller should simply break out of the wait loop.
fn wakeup(rio: *RemiellIo, wake_wait_point: *WaitPoint) bool {
    const our_wait_point = rio.waitPoint();

    if (our_wait_point == wake_wait_point)
        return false;

    const save_into = &our_wait_point.context;

    rio.current_coro = if (wake_wait_point == &rio.naked_wait)
        null
    else
        @fieldParentPtr("wait_point", wake_wait_point);

    _ = Io.fiber.contextSwitch(&.{
        .old = save_into,
        .new = &wake_wait_point.context,
    });

    return true;
}

fn addVector(
    comptime mut: Impl.Mutability,
    v: []Impl.Vector(mut),
    i: *usize,
    bytes: Impl.Vector(mut).Slice,
) void {
    if (bytes.len == 0) return;
    if (v.len - i.* == 0) return;
    v[i.*] = .init(bytes);
    i.* += 1;
}

pub const FileOperationMode = union(enum) {
    streaming: void,
    positional: u64,
};

pub const Operation = union(enum) {
    net_accept: NetAccept,
    net_read: NetRead,
    net_write: NetWrite,
    sleep: Sleep,
    cancel: Cancel,
    net_receive: NetReceive,
    net_send: NetSend,
    dir_open_file: DirOpenFile,
    file_read: FileRead,
    create_dir: CreateDir,
    dir_create_file: DirCreateFile,
    file_write: FileWrite,
    close: Close,

    pub const NetAccept = struct {
        listener_handle: Io.net.Socket.Handle,

        pub const Error = Io.net.Server.AcceptError;

        pub const Result = Error!Io.net.Socket;
    };

    pub const NetRead = struct {
        stream_handle: Io.net.Socket.Handle,

        // In case we need vectored I/O, this can be changed.
        buffer: []u8,

        pub const Error = Io.net.Stream.Reader.Error;

        // '0' indicates end of stream.
        pub const Result = Error!usize;
    };

    pub const NetWrite = struct {
        stream_handle: Io.net.Socket.Handle,
        data: []const Impl.Vector(.@"const"),

        pub const Error = Io.net.Stream.Writer.Error;

        pub const Result = Error!usize;
    };

    pub const Sleep = struct {
        milliseconds: u64,

        pub const Result = Io.Cancelable!void;
    };

    pub const Cancel = struct {
        operation: *Operation.Storage,

        pub const Result = void;
    };

    pub const NetReceive = struct {
        socket_handle: Io.net.Socket.Handle,
        from: *Io.net.IpAddress,
        buffer: []u8,

        pub const Error = Io.net.Socket.ReceiveError;

        pub const Result = Error!usize;
    };

    pub const NetSend = struct {
        socket_handle: Io.net.Socket.Handle,
        to: *const Io.net.IpAddress,
        buffer: []const u8,

        pub const Error = Io.net.Socket.SendError;

        pub const Result = Error!usize;
    };

    pub const DirOpenFile = struct {
        dir_handle: Io.Dir.Handle,
        sub_path: *Impl.PathBuffer,
        options: Io.Dir.OpenFileOptions,

        pub const Error = Io.File.OpenError;

        pub const Result = Error!Io.File.Handle;
    };

    pub const FileRead = struct {
        pub const vectored = native_os != .windows;

        file_handle: Io.File.Handle,
        mode: FileOperationMode,
        data: if (vectored)
            []const Impl.Vector(.@"var")
        else
            []u8,

        pub const Error = Io.File.ReadPositionalError ||
            Io.Operation.FileReadStreaming.Error ||
            Io.Cancelable;

        pub const Result = Error!usize;
    };

    pub const CreateDir = struct {
        at: Io.Dir.Handle,
        sub_path: *Impl.PathBuffer,
        permissions: Io.Dir.Permissions,

        pub const Error = Io.Dir.CreateDirError;

        pub const Result = Error!void;
    };

    pub const DirCreateFile = struct {
        at: Io.Dir.Handle,
        sub_path: *Impl.PathBuffer,
        options: Io.Dir.CreateFileOptions,

        pub const Error = Io.File.OpenError;

        pub const Result = Error!Io.File.Handle;
    };

    pub const FileWrite = struct {
        pub const vectored = native_os != .windows;

        file_handle: Io.File.Handle,
        mode: FileOperationMode,
        data: if (vectored)
            []const Impl.Vector(.@"const")
        else
            []const u8,

        pub const Error = Io.File.WritePositionalError ||
            Io.Operation.FileWriteStreaming.Error ||
            Io.Cancelable;

        pub const Result = Error!usize;
    };

    pub const Close = switch (native_os) {
        .linux => struct {
            handle: Io.File.Handle,
            pub const Result = void;
        },
        else => noreturn,
    };

    pub const Tag = @typeInfo(Operation).@"union".tag_type.?;

    pub const Result = Result: {
        const operation_fields = @typeInfo(Operation).@"union".fields;
        var field_names: [operation_fields.len][]const u8 = undefined;
        var field_types: [operation_fields.len]type = undefined;
        for (operation_fields, &field_names, &field_types) |field, *field_name, *field_type| {
            field_name.* = field.name;
            field_type.* = if (field.type == noreturn) noreturn else field.type.Result;
        }
        break :Result @Union(.auto, Tag, &field_names, &field_types, &@splat(.{}));
    };

    /// This structure must be pinned.
    pub const Storage = union {
        pub const WithAwaiter = struct {
            awaiter: union(enum) {
                synchronous: *WaitPoint,
                batch: *BatchUserdata,
            },
            storage: Storage,
        };

        submission: Submission,
        pending: Pending,
        completion: Completion,

        pub fn init(operation: Operation) Storage {
            return .{ .submission = .{
                .node = .{},
                .operation = operation,
            } };
        }

        pub const Submission = struct {
            node: std.DoublyLinkedList.Node,
            operation: Operation,
        };

        pub const Pending = struct {
            userdata: [16]usize,
        };

        pub const Completion = struct {
            node: std.DoublyLinkedList.Node,
            result: Operation.Result,

            pub fn parentPtr(c: *Completion, comptime Parent: type, comptime field_name: []const u8) *Parent {
                const storage: *Storage = @alignCast(@fieldParentPtr("completion", c));
                return @alignCast(@fieldParentPtr(field_name, storage));
            }
        };
    };
};

pub fn waitForShutdown(rio: *RemiellIo) void {
    const inner = struct {
        var rio_instance: *RemiellIo = undefined;

        // Windows only.
        var waiting_thread_handle: std.Thread.Handle = undefined;

        fn sigHandler(_: std.posix.SIG) callconv(.c) void {
            switch (rio_instance.shutdown) {
                .ignored => unreachable,
                .waiting => rio_instance.shutdown = .pending,
                .pending, .acknowledged => {},
            }
        }

        fn shutdownApc(_: windows.ULONG_PTR) callconv(.winapi) void {
            switch (rio_instance.shutdown) {
                .ignored => unreachable,
                .waiting => rio_instance.shutdown = .pending,
                .pending, .acknowledged => {},
            }
        }

        fn consoleCtrlHandler(_: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
            std.debug.assert(kernel32.QueueUserAPC(
                shutdownApc,
                waiting_thread_handle,
                0,
            ) != 0);

            return .TRUE;
        }
    };

    debug.assert(rio.shutdown == .ignored); // Tried to wait for shutdown twice.

    inner.rio_instance = rio;
    rio.shutdown = .waiting;
    rio.shutdown_wait_point = rio.waitPoint();

    if (is_windows) {
        std.debug.assert(windows.ntdll.NtOpenThread(
            &inner.waiting_thread_handle,
            windows.ACCESS_MASK.Specific.Thread.ALL_ACCESS,
            &.{ .ObjectName = null },
            &windows.teb().ClientId,
        ) == .SUCCESS);

        _ = kernel32.SetConsoleCtrlHandler(inner.consoleCtrlHandler, .TRUE);
    } else {
        _ = posix.system.sigaction(
            .INT,
            &.{
                .handler = .{ .handler = inner.sigHandler },
                .mask = std.mem.zeroes(@FieldType(posix.Sigaction, "mask")),
                .flags = 0,
            },
            null, // oldact
        );
    }

    rio.yield(.wait_for_shutdown);
}

test {
    _ = @import("RemiellIo/test.zig");
}

const is_windows = native_os == .windows;
const native_os = builtin.os.tag;
const is_debug = builtin.mode == .Debug;

const abort = std.process.abort;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;
const DefaultCsprng = std.Random.DefaultCsprng;

const net = std.Io.net;
const debug = std.debug;
const posix = std.posix;
const linux = std.os.linux;
const windows = std.os.windows;

const kernel32 = @import("RemiellIo/Iocp/kernel32.zig");

const std = @import("std");
const builtin = @import("builtin");
const RemiellIo = @This();
