const log = std.log.scoped(.@"remielle-gamesv::persistent");

const account_uid_map_path = "Persistent/LocalStorage/GENERAL_DATA.bin";
const calendar_path = "Persistent/LocalStorage/CALENDAR.bin";

const AccountUidMap = std.array_hash_map.Auto(AccountUid, void);
const base_player_uid = @import("config").base_player_uid;

root: Io.Dir,
account_uid_map: AccountUidMap,
calendar: logic.Calendar,

pub fn init(io: Io, gpa: Allocator, root: Io.Dir) !Persistent {
    try ensureDirectories(io, root);

    return .{
        .root = root,
        .account_uid_map = try loadAccountUidMap(io, gpa, root),
        .calendar = try loadCalendar(io, root),
    };
}

pub fn deinit(persistent: *Persistent, gpa: Allocator) void {
    persistent.account_uid_map.deinit(gpa);
}

pub const AccountUid = enum(u64) {
    _,

    pub fn fromString(account_uid: []const u8) ?AccountUid {
        return @enumFromInt(std.fmt.parseInt(u64, account_uid, 10) catch
            return null);
    }
};

pub fn getPlayerUid(persistent: *Persistent, account_uid: AccountUid) ?u32 {
    return if (persistent.account_uid_map.getIndex(account_uid)) |index|
        @intCast(base_player_uid + index)
    else
        null;
}

pub const GetOrCreatePlayerUid = struct {
    player_uid: u32,
    created: bool,
};

pub fn getOrCreatePlayerUid(
    persistent: *Persistent,
    io: Io,
    account_uid: AccountUid,
    gpa: Allocator,
) (Io.Cancelable || Allocator.Error || error{WriteFileFailed})!GetOrCreatePlayerUid {
    if (persistent.getPlayerUid(account_uid)) |player_uid|
        return .{ .player_uid = player_uid, .created = false };

    try persistent.account_uid_map.put(gpa, account_uid, {});

    persistent.root.writeFile(io, .{
        .sub_path = account_uid_map_path,
        .data = @ptrCast(persistent.account_uid_map.keys()),
    }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.WriteFileFailed,
    };

    return .{
        .player_uid = @intCast(base_player_uid + (persistent.account_uid_map.count() - 1)),
        .created = true,
    };
}

fn loadAccountUidMap(io: Io, gpa: Allocator, root: Io.Dir) !AccountUidMap {
    const bytes = root.readFileAllocOptions(io, account_uid_map_path, gpa, .unlimited, .of(u64), null) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        else => |e| return e,
    };

    defer gpa.free(bytes);

    var map: AccountUidMap = .empty;
    try map.reinit(gpa, @ptrCast(bytes), &.{});

    return map;
}

pub fn loadPlayer(
    persistent: *const Persistent,
    io: Io,
    arena: Allocator,
    player_uid: u32,
) !PlayerSave {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "Persistent/LocalStorage/USD_{d}.bin", .{player_uid}) catch
        unreachable;

    const file = try persistent.root.openFile(io, path, .{});
    defer file.close(io);

    var reader_buf: [1024]u8 = undefined;
    var fr = file.reader(io, &reader_buf);

    return try rmpb.decode(.stable, PlayerSave, arena, &fr.interface);
}

pub fn savePlayer(
    persistent: *const Persistent,
    io: Io,
    player_uid: u32,
    save: PlayerSave,
) !void {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "Persistent/LocalStorage/USD_{d}.bin", .{player_uid}) catch
        unreachable;

    const file = try persistent.root.createFile(io, path, .{});
    defer file.close(io);

    var writer_buf: [1024]u8 = undefined;
    var fw = file.writer(io, &writer_buf);

    try rmpb.encode(.stable, &fw.interface, save);
    try fw.interface.flush();
}

fn loadCalendar(io: Io, root: Io.Dir) !logic.Calendar {
    const file = root.openFile(io, calendar_path, .{}) catch |err| return switch (err) {
        error.FileNotFound => .init,
        else => |e| e,
    };

    defer file.close(io);

    var fr_buf: [1024]u8 = undefined;
    var fr = file.reader(io, &fr_buf);

    var calendar: logic.Calendar = undefined;
    calendar.load(&fr.interface) catch |err| return switch (err) {
        error.VersionMismatch => reset: {
            log.warn("calendar version mismatch, resetting defaults", .{});
            break :reset .init;
        },
        else => |e| e,
    };

    return calendar;
}

pub fn saveCalendar(persistent: *const Persistent, io: Io) !void {
    const file = try persistent.root.createFile(io, calendar_path, .{});
    defer file.close(io);

    var fw_buf: [1024]u8 = undefined;
    var fw = file.writer(io, &fw_buf);

    try persistent.calendar.save(&fw.interface);
    try fw.interface.flush();
}

fn ensureDirectories(io: Io, root: Io.Dir) !void {
    try root.createDirPath(io, "Persistent/LocalStorage/");
}

const Io = std.Io;
const Allocator = std.mem.Allocator;
const PlayerSave = rmpb.stable.PlayerSave;

const logic = @import("logic.zig");
const rmpb = @import("rmpb");
const std = @import("std");
const Persistent = @This();
