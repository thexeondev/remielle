// kcp/MultiConversation.zig - an implementation of "fast and reliable" ARQ protocol in zig.
//
// CONTRIBUTORS:
// xeondev (https://github.com/thexeondev)
//
// REFERENCES:
// Reference Implementation in C: https://github.com/skywind3000/kcp
//
// Copyright (c) 2026 ReversedRooms
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, version 3 of the License.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <www.gnu.org>.

const remielle = @import("remielle");
const mem = remielle.mem;

const min_rto: kcp.Timeval = .{ .milliseconds = 100 };
const max_rto: kcp.Timeval = .{ .milliseconds = 60000 };
const mss: usize = kcp.mtu - kcp.Header.size;

const SendRing = struct {
    // equal to client's rcvwnd
    pub const size: u32 = 256;

    sn: [size]u32,
    frg: [size]kcp.Header.Fragment,
    len: [size]u16,
    resend_ts: [size]kcp.Timeval,
    rto: [size]kcp.Timeval,
    fastack: [size]u8,
    xmit: [size]u8,
    buffers: [size][mss]u8,

    head: u32,
    tail: u32,

    pub fn reset(ring: *SendRing) void {
        @memset(&ring.sn, 0);

        ring.head = 0;
        ring.tail = 0;
    }

    pub fn pop(ring: *SendRing) ?u32 {
        while (ring.head != ring.tail) {
            defer ring.head += 1;

            if (ring.sn[ring.head % SendRing.size] == ring.head)
                return ring.head % SendRing.size;
        }

        return null;
    }

    pub fn unused(ring: *SendRing) u16 {
        return @truncate(SendRing.size - (ring.tail -% ring.head));
    }

    pub fn ack(ring: *SendRing, ack_sn: u32) void {
        if (ack_sn >= ring.head and ack_sn < ring.tail) {
            ring.sn[ack_sn % SendRing.size] = 0;

            while (ring.head < ring.tail and ring.sn[ring.head % SendRing.size] == 0)
                ring.head += 1;
        }
    }

    pub fn shiftUna(ring: *SendRing, una: u32) void {
        if (una > ring.tail) return;

        while (ring.head < una) : (ring.head += 1) {
            ring.sn[ring.head % SendRing.size] = 0;
        }
    }

    pub fn markFastack(ring: *SendRing, maxack: u32, current: kcp.Timeval) void {
        var sn = ring.head;
        while (sn < maxack) : (sn += 1) {
            const seg = sn % SendRing.size;
            if (ring.sn[seg] != sn) continue;

            if (ring.fastack[seg] != 0) {
                ring.fastack[seg] = 0;
                ring.resend_ts[seg] = current;
            } else {
                ring.fastack[seg] = 1;
            }
        }
    }
};

const RecvRing = struct {
    // equal to client's sndwnd
    pub const size: u32 = 512;

    frg: [size]kcp.Header.Fragment,
    sn: [size]u32,
    len: [size]u16,
    buffers: [size][mss]u8,

    head: u32,
    tail: u32,

    pub fn reset(ring: *RecvRing) void {
        @memset(&ring.sn, 0);

        ring.head = 0;
        ring.tail = 0;
    }

    pub fn pop(ring: *RecvRing) ?u32 {
        if (ring.head == ring.tail)
            return null;

        if (ring.sn[ring.head % size] != ring.head)
            return null;

        defer ring.head += 1;
        return ring.head % size;
    }

    pub fn unused(ring: *RecvRing) u16 {
        return @truncate(RecvRing.size - (ring.tail -% ring.head));
    }
};

const AckRing = struct {
    // equal to client's sndwnd
    pub const size: u32 = 512;

    pub const Entry = packed struct {
        sn: u32,
        ts: kcp.Timeval,
    };

    entries: [size]Entry,
    head: u16,
    tail: u16,

    pub fn push(ring: *AckRing, sn: u32, ts: kcp.Timeval) void {
        defer ring.tail += 1;
        ring.entries[ring.tail] = .{ .sn = sn, .ts = ts };
    }

    pub fn pop(ring: *AckRing) ?Entry {
        if (ring.head == ring.tail) return null;

        defer ring.head += 1;
        return ring.entries[ring.head];
    }

    pub fn reset(ring: *AckRing) void {
        ring.head = 0;
        ring.tail = 0;
    }
};

const Rx = struct {
    rttval: u32,
    srtt: kcp.Timeval,
    rto: kcp.Timeval,

    pub const init: Rx = .{
        .rttval = 0,
        .srtt = .zero,
        .rto = .zero,
    };

    pub fn refresh(rx: *Rx, rtt_ms: u32) void {
        if (rx.srtt.milliseconds == 0) {
            rx.srtt.milliseconds = rtt_ms;
            rx.rttval = @divTrunc(rtt_ms, 2);
        } else {
            const delta_i: i32 = @bitCast(rtt_ms -% rx.srtt.milliseconds);
            const delta: u32 = @intCast(if (delta_i < 0) -delta_i else delta_i);

            rx.rttval = @divTrunc((3 * rx.rttval + delta), 4);
            rx.srtt.milliseconds = @divTrunc((7 * rx.srtt.milliseconds + rtt_ms), 8);
            rx.srtt.milliseconds = @max(rx.srtt.milliseconds, 1);
        }

        const interval: u32 = 100;
        const rto = rx.srtt.milliseconds + @max(
            interval,
            4 * rx.rttval,
        );

        rx.rto.milliseconds = std.math.clamp(
            rto,
            min_rto.milliseconds,
            max_rto.milliseconds,
        );
    }
};

pub const Identifier = struct {
    id: kcp.ConvId,
    token: kcp.Token,
};

const Rings = struct {
    node: SinglyLinkedList.Node,
    send: SendRing,
    recv: RecvRing,
    ack: AckRing,

    const Pool = struct {
        pub const init: Pool = .{ .free = .{} };

        free: SinglyLinkedList,

        fn create(pool: *Pool, arena: Allocator) Allocator.Error!*Rings {
            if (pool.free.popFirst()) |node|
                return @alignCast(@fieldParentPtr("node", node));

            return arena.create(Rings);
        }

        inline fn recycle(pool: *Pool, rings: *Rings) void {
            pool.free.prepend(&rings.node);
        }
    };
};

const OptionalIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn toInt(oi: OptionalIndex) u32 {
        std.debug.assert(oi != .none);
        return @intFromEnum(oi);
    }
};

const List = struct {
    head: OptionalIndex,

    pub const empty: List = .{ .head = .none };

    pub const Node = struct { next: OptionalIndex };
};

const Conversation = struct {
    identifier: Identifier,
    node: List.Node,
    rings: *Rings,

    start_time: kcp.Timeval,
    last_update: kcp.Timeval,

    rx: Rx,
    undrained: bool,
};

const Storage = mem.RemielleArrayList(
    mem.suggestBucketSize(64, Conversation),
    Conversation,
    u32,
);

storage: Storage,
undrained: List,
rings_pool: Rings.Pool,

pub const init: MultiConversation = .{
    .storage = .empty,
    .undrained = .{ .head = .none },
    .rings_pool = .init,
};

pub fn swapRemove(mc: *MultiConversation, conv_idx: u32) void {
    mc.rings_pool.recycle(mc.storage.get(.rings, conv_idx));
    mc.storage.swapRemove(conv_idx);
}

pub fn create(
    mc: *MultiConversation,
    arena: Allocator,
    conv_id: kcp.ConvId,
    token: kcp.Token,
    start_time: Io.Timestamp,
) Allocator.Error!u32 {
    const global_index = mc.storage.addOne() catch
        return error.OutOfMemory;

    const bucket = mc.storage.buckets.items[global_index / Storage.bucket_capacity];
    const index = global_index % Storage.bucket_capacity;

    errdefer mc.storage.item_count -= 1;

    const rings = try mc.rings_pool.create(arena);
    errdefer comptime unreachable;

    rings.send.reset();
    rings.recv.reset();
    rings.ack.reset();

    bucket.identifier[index] = .{ .id = conv_id, .token = token };
    bucket.rings[index] = rings;
    bucket.start_time[index] = .fromTimestamp(start_time);
    bucket.last_update[index] = .zero;
    bucket.rx[index] = .init;

    return global_index;
}

pub const Reader = struct {
    ring: *RecvRing,
    /// Current Seg index.
    cur: u32,
    /// The amount of bytes "stolen" from next Seg's buffer.
    seek_next: usize,
    interface: Io.Reader,

    pub fn init(ring: *RecvRing) Reader {
        const head = ring.head % RecvRing.size;

        return .{
            .ring = ring,
            .cur = head,
            .seek_next = 0,
            .interface = .{
                .vtable = &.{
                    .stream = stream,
                    .readVec = readVec,
                    .rebase = rebase,
                },
                .buffer = ring.buffers[head][0..ring.len[head]],
                .end = ring.len[head],
                .seek = 0,
            },
        };
    }

    fn stream(io_r: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        try nextBuffer(io_r);
        return 0;
    }

    fn readVec(io_r: *Io.Reader, _: [][]u8) Io.Reader.Error!usize {
        try nextBuffer(io_r);
        return 0;
    }

    fn rebase(io_r: *Io.Reader, capacity: usize) Io.Reader.RebaseError!void {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));

        switch (r.ring.frg[r.cur]) {
            .last => return error.EndOfStream,
            _ => {
                if (io_r.seek == io_r.end)
                    return nextBuffer(io_r);

                // This means that rebase was called repeatedly. Should not happen.
                if (r.seek_next != 0)
                    return error.ReadFailed;

                // Copy the leftover buffered data to the beginning of current buffer.
                const leftover = io_r.end - io_r.seek;
                @memmove(io_r.buffer[0..leftover], io_r.buffer[io_r.seek..io_r.end]);

                io_r.seek = 0;
                io_r.end = leftover;
                io_r.buffer.len = leftover;

                // Steal some data from the next buffer.
                const next_seg = (r.cur + 1) % RecvRing.size;
                const next_buffer = r.ring.buffers[next_seg][0..r.ring.len[next_seg]];

                if (capacity > io_r.end + next_buffer.len)
                    return error.EndOfStream;

                @memcpy(io_r.buffer[leftover..capacity], next_buffer[0 .. capacity - leftover]);

                io_r.buffer.len = capacity;
                io_r.end = capacity;
                r.seek_next = capacity - leftover;
            },
        }
    }

    fn nextBuffer(io_r: *Io.Reader) Io.Reader.Error!void {
        if (io_r.seek != io_r.end) return;
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));

        switch (r.ring.frg[r.cur]) {
            .last => return error.EndOfStream,
            _ => {
                r.cur = (r.cur + 1) % RecvRing.size;
                io_r.buffer = r.ring.buffers[r.cur][0..r.ring.len[r.cur]];
                io_r.end = r.ring.len[r.cur];
                io_r.seek = r.seek_next;
                r.seek_next = 0;
            },
        }
    }
};

pub inline fn identifierAt(mc: *MultiConversation, index: u32) Identifier {
    return mc.storage.get(.identifier, index);
}

pub fn reader(mc: *MultiConversation, index: u32) ?Reader {
    return if (mc.isReadable(index))
        .init(&mc.storage.get(.rings, index).recv)
    else
        null;
}

/// Discards one kcp packet.
pub fn discardAt(mc: *MultiConversation, client: u32) void {
    const ring = &mc.storage.get(.rings, client).recv;

    while (ring.pop()) |index| {
        ring.sn[index] = 0;

        switch (ring.frg[index]) {
            .last => break,
            _ => {},
        }
    }
}

fn isReadable(mc: *MultiConversation, client: u32) bool {
    const ring = &mc.storage.get(.rings, client).recv;

    const ring_head = ring.head;
    defer ring.head = ring_head;

    const first = ring.pop() orelse
        return false;

    return switch (ring.frg[first]) {
        .last => true,
        _ => walk_segments: {
            while (ring.pop()) |index| {
                switch (ring.frg[index]) {
                    .last => break :walk_segments true,
                    _ => {},
                }
            }

            break :walk_segments false;
        },
    };
}

pub const Writer = struct {
    ring: *SendRing,
    cur: usize,
    interface: Io.Writer,

    pub fn init(ring: *SendRing, first: u32) Writer {
        return .{
            .ring = ring,
            .cur = first,
            .interface = .{
                .buffer = &ring.buffers[first % SendRing.size],
                .vtable = &.{ .drain = drain },
            },
        };
    }

    pub fn drain(io_w: *Io.Writer, _: []const []const u8, _: usize) Io.Writer.Error!usize {
        if (io_w.end != io_w.buffer.len) return 0;

        const seg_w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
        if (seg_w.cur == seg_w.ring.tail - 1) return error.WriteFailed;

        seg_w.cur += 1;
        const index = seg_w.cur % SendRing.size;

        io_w.buffer = &seg_w.ring.buffers[index];
        io_w.end = 0;

        return 0;
    }
};

pub const AllocWriterError = error{
    MessageOversize,
};

pub fn writer(mc: *MultiConversation, client: u32, size: usize) AllocWriterError!Writer {
    const ring = &mc.storage.get(.rings, client).send;

    var count: usize = (size + mss - 1) / mss;

    if (count >= ring.unused())
        return error.MessageOversize;

    var full_size = size;
    const first: u32 = ring.tail;

    while (count > 0) : ({
        count -= 1;
        ring.tail += 1;
        full_size -|= mss;
    }) {
        const index = ring.tail % SendRing.size;

        ring.sn[index] = ring.tail;
        ring.frg[index] = @enumFromInt(count - 1);
        ring.len[index] = @truncate(@min(mss, full_size));
        ring.resend_ts[index] = .zero;
        ring.rto[index] = .zero;
        ring.fastack[index] = 0;
        ring.xmit[index] = 0;
    }

    if (!mc.storage.swapBit(.undrained, client, true)) {
        mc.storage.getPtr(.node, client).next = mc.undrained.head;
        mc.undrained.head = @enumFromInt(client);
    }

    return .init(ring, first);
}

pub fn fillAt(mc: *MultiConversation, client_index: u32, data: []const u8) !void {
    const current = mc.storage.get(.last_update, client_index);
    const rings = mc.storage.get(.rings, client_index);

    var maxack: u32 = 0;
    var latest_ts: kcp.Timeval = .zero;
    var has_acks: bool = false;

    var buf_reader: Io.Reader = .fixed(data);

    while (buf_reader.bufferedLen() >= kcp.Header.size) {
        const header = try kcp.Header.decode(buf_reader.takeArray(kcp.Header.size) catch unreachable);
        const buf = try buf_reader.take(header.len);

        rings.send.shiftUna(header.una);

        switch (header.cmd) {
            .ack => {
                if (current.milliseconds >= header.ts.milliseconds)
                    mc.storage.getPtr(.rx, client_index).refresh(current.milliseconds - header.ts.milliseconds);

                rings.send.ack(header.sn);

                if (!has_acks) {
                    has_acks = true;
                    maxack = header.sn;
                    latest_ts = header.ts;
                } else if (header.sn > maxack and header.ts.milliseconds > latest_ts.milliseconds) {
                    maxack = header.sn;
                    latest_ts = header.ts;
                }
            },
            .push => {
                if (header.sn >= rings.recv.tail and header.sn < rings.recv.tail + RecvRing.size) {
                    const seg = header.sn % RecvRing.size;

                    if (rings.recv.sn[seg] != header.sn or header.sn == rings.recv.tail) {
                        rings.recv.sn[seg] = header.sn;
                        rings.recv.frg[seg] = header.frg;
                        rings.recv.len[seg] = @intCast(header.len);
                        @memcpy(rings.recv.buffers[seg][0..buf.len], buf);
                    }

                    while (rings.recv.sn[rings.recv.tail % RecvRing.size] == rings.recv.tail)
                        rings.recv.tail += 1;

                    rings.ack.push(header.sn, header.ts);
                }
            },
            .wask, .wins => {},
        }
    }

    if (has_acks)
        rings.send.markFastack(maxack, latest_ts);

    if (!mc.storage.swapBit(.undrained, client_index, true)) {
        mc.storage.getPtr(.node, client_index).next = mc.undrained.head;
        mc.undrained.head = @enumFromInt(client_index);
    }
}

pub fn nextUndrained(mc: *MultiConversation) ?u32 {
    return switch (mc.undrained.head) {
        .none => null,
        _ => |oi| take: {
            const index = oi.toInt();
            const node = mc.storage.getPtr(.node, index);

            mc.undrained.head = node.next;
            node.next = .none;

            _ = mc.storage.swapBit(.undrained, index, false);

            break :take index;
        },
    };
}

pub const DrainIterator = union(enum) {
    init: void,
    index: usize,
    ended: void,

    pub fn isAtEnd(it: *const DrainIterator) bool {
        return switch (it.*) {
            .ended => true,
            .init, .index => false,
        };
    }
};

// Drains outgoing segment queue into user-provided `output` buffer.
// Returns the amount of bytes drained.
// This function should be called repeatedly, while `DrainIterator` is not at end.
pub fn drainAt(mc: *MultiConversation, client: u32, it: *DrainIterator, output: *[kcp.mtu]u8) usize {
    const identifier = mc.storage.get(.identifier, client);
    const current = mc.storage.get(.last_update, client);
    const rings = mc.storage.get(.rings, client);

    const wnd = rings.recv.unused();
    const una = rings.recv.tail;

    var bw: Io.Writer = .fixed(output);
    var ack_header: kcp.Header = .{
        .conv_id = identifier.id,
        .token = identifier.token.downgrade(),
        .cmd = .ack,
        .frg = .last,
        .wnd = wnd,
        .ts = .zero,
        .sn = 0,
        .una = una,
        .len = 0,
    };

    while (rings.ack.pop()) |entry| {
        if (bw.end + kcp.Header.size > kcp.mtu) {
            rings.ack.head -= 1;
            return bw.end;
        }

        ack_header.sn = entry.sn;
        ack_header.ts = entry.ts;
        ack_header.encode(&bw) catch unreachable;
    }

    rings.ack.reset();

    const rx_rto = mc.storage.getPtr(.rx, client).rto;

    const it_index = switch (it.*) {
        .init => init: {
            it.* = .{ .index = rings.send.head };
            break :init &it.index;
        },
        .index => |*index| index,
        .ended => return bw.end,
    };

    while (true) {
        const index = next: while (it_index.* != rings.send.tail) {
            defer it_index.* += 1;

            if (rings.send.sn[it_index.* % SendRing.size] == it_index.*)
                break :next it_index.* % SendRing.size;
        } else {
            it.* = .ended;
            return bw.end;
        };

        const retransmit = rings.send.xmit[index] != 0;

        if (!retransmit or current.milliseconds >= rings.send.resend_ts[index].milliseconds) {
            const len = rings.send.len[index];
            if (bw.end + len + kcp.Header.size > kcp.mtu) {
                it_index.* -= 1; // we'll send it on the next `drain` call.
                return bw.end;
            }

            if (retransmit) {
                rings.send.rto[index].milliseconds += rings.send.rto[index].milliseconds / 2;
                rings.send.resend_ts[index].milliseconds = current.milliseconds + rings.send.rto[index].milliseconds;
                rings.send.fastack[index] = 0;
            } else {
                rings.send.resend_ts[index].milliseconds = current.milliseconds + rx_rto.milliseconds;
                rings.send.rto[index] = rx_rto;
            }

            rings.send.xmit[index] += 1;

            const header: kcp.Header = .{
                .conv_id = identifier.id,
                .token = identifier.token.downgrade(),
                .cmd = .push,
                .frg = rings.send.frg[index],
                .wnd = wnd,
                .ts = current,
                .sn = rings.send.sn[index],
                .una = una,
                .len = rings.send.len[index],
            };

            header.encode(&bw) catch unreachable;
            bw.writeAll(rings.send.buffers[index][0..header.len]) catch unreachable;
        }
    }

    return bw.end;
}

pub fn updateAt(mc: *MultiConversation, client: u32, current_time: Io.Timestamp) void {
    const start = mc.storage.get(.start_time, client);
    const current: kcp.Timeval = .fromTimestamp(current_time);

    mc.storage.getPtr(.last_update, client).milliseconds = current.milliseconds -| start.milliseconds;
    const ring = &mc.storage.get(.rings, client).send;

    // Update `ring.head`
    if (ring.pop() != null)
        ring.head -= 1;
}

const Io = std.Io;
const Allocator = std.mem.Allocator;
const SinglyLinkedList = std.SinglyLinkedList;

const kcp = @import("../kcp.zig");

const std = @import("std");
const MultiConversation = @This();
