const remielle = @import("remielle");
const pb = remielle.protobuf.main;

const logic = @import("../../logic.zig");
const Properties = logic.Properties;

const handlers = @import("../handlers.zig");
const Scope = handlers.Scope;

const packers = @import("../packers.zig");

pub fn QuickTeamEditCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.QuickTeamEditCsReq);
    const quick_team_data = request.quick_team orelse
        return try scope.sink.respond(pb.QuickTeamEditScRsp, .{ .retcode = 1 });

    for (quick_team_data.quick_team_list.items) |quick_team| {
        const slot = Properties.QuickTeam.Slot.fromInt(quick_team.slot) orelse
            return try scope.sink.respond(pb.QuickTeamEditScRsp, .{ .retcode = 1 });

        if (quick_team.avatar_list.items.len > 3 or
            quick_team.buddy_list.items.len > 1)
            return try scope.sink.respond(pb.QuickTeamEditScRsp, .{ .retcode = 1 });

        var meta: Properties.QuickTeam.Meta = .{
            .name = Properties.QuickTeam.Name.fromSlice(quick_team.name) catch
                return try scope.sink.respond(pb.QuickTeamEditScRsp, .{ .retcode = 1 }),

            .avatar_ids = @splat(.none),
            .buddy_id = .none,
        };

        for (quick_team.avatar_list.items, 0..) |avatar, i|
            meta.avatar_ids[i] = @fromBackingInt(@intCast(avatar.avatar_id));

        if (quick_team.buddy_list.items.len == 1)
            meta.buddy_id = @fromBackingInt(@intCast(quick_team.buddy_list.items[0].buddy_id));

        scope.properties.quick_team.meta[slot.toIndex()] = meta;
    }

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .misc = .{ .quick_team = .{
            .quick_team_list = try packers.packQuickTeamList(
                scope.sink.allocator,
                &scope.properties.quick_team.meta,
            ),
        } },
    });

    try scope.sink.respond(pb.QuickTeamEditScRsp, .init);
}

pub fn QuickTeamModNameCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.QuickTeamModNameCsReq);

    const slot = Properties.QuickTeam.Slot.fromInt(request.slot) orelse
        return try scope.sink.respond(pb.QuickTeamModNameScRsp, .{ .retcode = 1 });

    scope.properties.quick_team.meta[slot.toIndex()].name.set(request.name) catch
        return try scope.sink.respond(pb.QuickTeamModNameScRsp, .{ .retcode = 1 });

    try scope.sink.notify(pb.PlayerSyncScNotify, .{
        .misc = .{ .quick_team = .{
            .quick_team_list = try packers.packQuickTeamList(
                scope.sink.allocator,
                &scope.properties.quick_team.meta,
            ),
        } },
    });

    try scope.sink.respond(pb.QuickTeamModNameScRsp, .init);
}
