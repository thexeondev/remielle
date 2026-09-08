const std = @import("std");
const Io = std.Io;
const process = std.process;
const fatal = std.process.fatal;

pub fn main(init: process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const to_spawn = args[1..];

    const select_buf = try gpa.alloc(SpawnResult, to_spawn.len);
    defer gpa.free(select_buf);

    var select: Io.Select(SpawnResult) = .init(io, select_buf);
    defer select.cancelDiscard();

    for (to_spawn) |path| try select.concurrent(
        .one,
        spawnAndWait,
        .{ io, path },
    );

    // Once one of them dies with non-zero exit code, kill the rest.
    while ((try select.await()).one) |term| {
        switch (term) {
            .exited => |code| if (code != 0) break,
            .signal, .stopped, .unknown => break,
        }
    } else |err| switch (err) {
        error.Canceled => unreachable,
        else => |e| fatal("spawnAndWait failed: {t}", .{e}),
    }
}

const SpawnResult = union(enum) {
    one: SpawnAndWaitError!process.Child.Term,
};

const SpawnAndWaitError = process.Child.WaitError || process.SpawnError;

fn spawnAndWait(io: Io, path: []const u8) SpawnAndWaitError!process.Child.Term {
    var child = try process.spawn(io, .{ .argv = &.{path} });
    defer child.kill(io);

    return try child.wait(io);
}
