const Passwd = @This();
const std = @import("std");
const Io = std.Io;
const heap = std.heap;
const Random = std.Random;
const Allocator = std.mem.Allocator;
const bcrypt = std.crypto.pwhash.bcrypt;
const array_hash_map = std.array_hash_map;
const MultiArrayList = std.MultiArrayList;

const remielle = @import("remielle");
const LimitedString = remielle.mem.LimitedString;

const save_path = "Persistent/SDK/passwd";

sync: Io.RwLock,
name_map: array_hash_map.Auto(Name, void),
list: MultiArrayList(struct {
    token: Token,
    secret: Secret,
}),

pub const Id = enum(u64) {
    pub const fmt_len = 32;

    _,

    pub fn fromSlice(slice: []const u8) ?Id {
        const int = std.fmt.parseInt(u64, slice, 10) catch return null;

        return switch (int) {
            0 => null,
            else => @enumFromInt(int),
        };
    }

    pub fn toString(id: Id, buf: *[fmt_len]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{@intFromEnum(id)}) catch unreachable;
    }

    inline fn fromIndex(index: usize) Id {
        return @enumFromInt(index + 1);
    }

    inline fn toIndex(id: Id) usize {
        return @intFromEnum(id) - 1;
    }
};

pub fn load(io: Io, gpa: Allocator, root: Io.Dir) !Passwd {
    var passwd: Passwd = .{
        .sync = .init,
        .name_map = .empty,
        .list = .empty,
    };

    errdefer passwd.deinit(gpa);

    const file = root.openFile(io, save_path, .{}) catch |err| return switch (err) {
        error.FileNotFound => passwd,
        else => |e| e,
    };

    defer file.close(io);

    var fr_buf: [8]u8 = undefined;
    var fr = file.readerStreaming(io, &fr_buf);
    const reader = &fr.interface;

    const count = try reader.takeInt(u64, .little);

    try passwd.name_map.ensureTotalCapacity(gpa, count);
    try passwd.list.ensureTotalCapacity(gpa, count);

    passwd.name_map.entries.len = count;
    passwd.list.len = count;

    var vec: [3][]u8 = .{
        std.mem.sliceAsBytes(passwd.name_map.keys()),
        std.mem.sliceAsBytes(passwd.list.items(.token)),
        std.mem.sliceAsBytes(passwd.list.items(.secret)),
    };

    try reader.readVecAll(&vec);
    try passwd.name_map.reIndex(gpa);

    return passwd;
}

pub fn save(passwd: *Passwd, io: Io, root: Io.Dir) !void {
    try root.createDirPath(io, "Persistent/SDK/");

    const file = try root.createFile(io, save_path, .{});
    defer file.close(io);

    const count: u64 = std.mem.nativeToLittle(u64, @intCast(passwd.list.len));

    const list = passwd.list.slice();
    var vec: [4][]const u8 = .{
        std.mem.asBytes(&count),
        std.mem.sliceAsBytes(passwd.name_map.keys()),
        std.mem.sliceAsBytes(list.items(.token)),
        std.mem.sliceAsBytes(list.items(.secret)),
    };

    var fw = file.writerStreaming(io, &.{});
    try fw.interface.writeVecAll(&vec);
}

pub fn deinit(passwd: *Passwd, gpa: Allocator) void {
    passwd.name_map.deinit(gpa);
    passwd.list.deinit(gpa);
}

pub fn getName(passwd: *const Passwd, id: Id) ?*const Name {
    const index = id.toIndex();
    if (passwd.name_map.entries.len <= index)
        return null;

    return &passwd.name_map.keys()[index];
}

pub fn getToken(passwd: *const Passwd, id: Id) ?*const Token {
    const index = id.toIndex();
    if (passwd.list.len <= index)
        return null;

    return &passwd.list.items(.token)[index];
}

pub fn loginByPassword(passwd: *const Passwd, name: Name, password: []const u8) !Id {
    const index = passwd.name_map.getIndex(name) orelse
        return error.UsernameNotExist;

    if (!passwd.list.items(.secret)[index].eql(password))
        return error.PasswordMismatch;

    return .fromIndex(index);
}

/// Doesn't check if username already exists.
/// Doesn't flush to the disk.
pub fn create(
    passwd: *Passwd,
    io: Io,
    gpa: Allocator,
    name: Name,
    password: []const u8,
) !Id {
    const secret: Secret = try .fromPassword(io, password);
    const token: Token = .random(io);

    try passwd.list.ensureUnusedCapacity(gpa, 1);
    try passwd.name_map.ensureUnusedCapacity(gpa, 1);

    errdefer comptime unreachable;

    const index = passwd.list.addOneAssumeCapacity();
    const slice = passwd.list.slice();

    slice.items(.token)[index] = token;
    slice.items(.secret)[index] = secret;

    passwd.name_map.putAssumeCapacity(name, {});

    return .fromIndex(index);
}

pub const Name = struct {
    string: LimitedString(31),

    pub fn fromSlice(slice: []const u8) !Name {
        var name: Name = .{ .string = try .fromSlice(slice) };
        @memset(name.string.bytes[slice.len..], 0);
        return name;
    }
};

pub const Secret = struct {
    hash: LimitedString(256),

    pub fn fromPassword(io: Io, password: []const u8) !Secret {
        var result: Secret = undefined;

        const hash = try bcrypt.strHash(password, .{
            .encoding = .phc,
            .params = .owasp,
        }, result.hash.bytes[0..256], io);

        @memset(result.hash.bytes[hash.len..], 0);

        return result;
    }

    pub fn eql(secret: *const Secret, plain: []const u8) bool {
        bcrypt.strVerify(secret.hash.view(), plain, .{
            .silently_truncate_password = false,
        }) catch return false;

        return true;
    }
};

pub const Token = struct {
    pub const length = 64;

    string: [length]u8,

    pub fn random(io: Io) Token {
        var token: Token = undefined;

        const rng_source: Random.IoSource = .{ .io = io };
        const rng = rng_source.interface();

        for (&token.string) |*char|
            char.* = rng.intRangeAtMost(u8, 97, 122);

        return token;
    }

    pub fn eql(token: *const Token, userdata: []const u8) bool {
        return std.mem.eql(u8, &token.string, userdata);
    }
};
