const Account = @This();

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const bcrypt = std.crypto.pwhash.bcrypt;
const MultiArrayList = std.MultiArrayList;

username: Username,
password: Password,
token: Token,

const field_count = @typeInfo(Account).@"struct".field_names.len;

pub const Username = extern struct {
    pub const length_max = 15;

    const Bytes = [length_max:0]u8;

    /// All the inactive bytes are zeroes.
    bytes: Bytes,

    comptime {
        assert(@sizeOf(Bytes) == @sizeOf(u128));
    }

    fn toU128(username: *const Username) u128 {
        return @bitCast(username.bytes);
    }

    pub fn fromSlice(slice: []const u8) ?Account.Username {
        if (slice.len == 0) return null;
        if (Account.Username.length_max < slice.len) return null;

        var result: Username = undefined;
        defer assert(result.bytes[length_max] == 0);

        for (slice) |char|
            if (!std.ascii.isAlphanumeric(char) and char != '_')
                return null;

        @memcpy(result.bytes[0..slice.len], slice);
        @memset(result.bytes[slice.len..], 0);
        result.bytes[length_max] = 0;

        return result;
    }

    pub fn toSlice(username: *const Username) [:0]const u8 {
        assert(username.bytes[length_max] == 0);
        return mem.span(@as([*:0]const u8, &username.bytes));
    }

    const Map = std.array_hash_map.Auto(void, void);

    const Adapter = struct {
        usernames: []const Username,

        pub fn eql(context: Adapter, a: Username, b_void: void, b_map_index: usize) bool {
            _ = b_void;
            return a.toU128() == context.usernames[b_map_index].toU128();
        }

        pub fn hash(context: Adapter, a: Username) u32 {
            _ = context;
            return std.array_hash_map.hashString(&a.bytes);
        }
    };
};

pub const Password = extern struct {
    hash: [67]u8,

    pub fn init(csprng: std.Random, string: []const u8) Password {
        var salt: [bcrypt.salt_length]u8 = undefined;
        csprng.bytes(&salt);

        var pw: Password = undefined;
        // The error set of this function is a mess,
        // it's generalized for all kinds of hashers,
        // some of them spawn threads, etc.
        const hash_slice = bcrypt.strHashWithSalt(string, .{
            .encoding = .phc,
            .params = .owasp,
        }, &pw.hash, salt) catch unreachable;
        assert(hash_slice.len == pw.hash.len);
        return pw;
    }

    pub fn verify(pw: *const Password, string: []const u8) bool {
        return if (bcrypt.strVerify(&pw.hash, string, .{
            .silently_truncate_password = false,
        }))
            true
        else |err| switch (err) {
            error.Canceled => unreachable, // No `Io` involved.
            else => false,
        };
    }
};

pub const Token = extern struct {
    pub const length = 64;

    chars: [length]u8,

    pub fn random(csprng: std.Random) Token {
        var t: Token = undefined;
        for (&t.chars) |*char|
            char.* = csprng.intRangeAtMost(u8, 'a', 'z');

        return t;
    }

    pub fn eql(token: *const Token, string: []const u8) bool {
        return mem.eql(u8, &token.chars, string);
    }
};

pub const Index = enum(u64) {
    _,

    pub fn fromUid(uid: u64) ?Account.Index {
        if (uid == 0) return null;
        return @fromBackingInt(uid - 1);
    }

    pub fn toUid(index: Account.Index) u64 {
        return @backingInt(index) + 1;
    }
};

pub const Storage = struct {
    list: MultiArrayList(Account),
    username_map: Account.Username.Map,

    pub const Header = extern struct {
        pub const current_version: u32 = 1;

        version: u32,
        item_count: u32,
    };

    pub fn count(storage: *const Storage) usize {
        return storage.list.len;
    }

    pub fn writableVector(storage: *Storage) [Account.field_count][]u8 {
        var vector: [Account.field_count][]u8 = undefined;
        const accounts_slice = storage.list.slice();

        inline for (
            &vector,
            std.enums.values(MultiArrayList(Account).Field),
        ) |*buffer, field| {
            buffer.* = @ptrCast(accounts_slice.items(field));
        }

        return vector;
    }

    pub fn readableVector(storage: *const Storage) [Account.field_count][]const u8 {
        return writableVector(@constCast(storage));
    }

    pub fn initCapacity(arena: Allocator, capacity: u32) Allocator.Error!Storage {
        return .{
            .list = try .initCapacity(arena, capacity),
            .username_map = username_map: {
                var map: Account.Username.Map = .empty;
                try map.ensureTotalCapacity(arena, capacity);
                break :username_map map;
            },
        };
    }

    pub fn reIndexAssumeFirstIndexing(storage: *Account.Storage) void {
        assert(storage.username_map.entries.len == 0);

        const username_slice = storage.list.items(.username);
        const username_adapter: Username.Adapter = .{ .usernames = username_slice };

        for (username_slice, 0..) |username, index| {
            const gop = storage.username_map.getOrPutAssumeCapacityAdapted(
                username,
                username_adapter,
            );

            assert(!gop.found_existing);
            assert(gop.index == index);
        }
    }

    pub fn getByIndex(storage: *const Account.Storage, index: Account.Index) ?Account {
        const index_int = @backingInt(index);
        if (storage.list.len <= index_int) return null;

        return storage.list.get(index_int);
    }

    pub const GetOrInsertError = error{
        /// The account with specified username was not found
        /// and the storage is full.
        AccountStorageCapacityExceeded,
    };

    pub const GetOrInsertResult = struct {
        found: bool,
        index: Account.Index,
    };

    pub fn getOrInsertByUsername(
        storage: *Account.Storage,
        account: Account,
    ) GetOrInsertError!GetOrInsertResult {
        assert(storage.list.len == storage.username_map.entries.len);

        const username_adapter: Username.Adapter = .{
            .usernames = storage.list.items(.username),
        };

        if (storage.list.len == storage.list.capacity) {
            const index_int = storage.username_map.getIndexAdapted(
                account.username,
                username_adapter,
            ) orelse
                return error.AccountStorageCapacityExceeded;

            return .{
                .found = true,
                .index = @fromBackingInt(@intCast(index_int)),
            };
        }

        const gop = storage.username_map.getOrPutAssumeCapacityAdapted(
            account.username,
            username_adapter,
        );

        if (!gop.found_existing) {
            // New account, we must append it to the list.
            storage.list.appendAssumeCapacity(account);
            const list_index = storage.list.len - 1;
            assert(gop.index == list_index);
        }

        return .{
            .found = gop.found_existing,
            .index = @fromBackingInt(@intCast(gop.index)),
        };
    }
};
