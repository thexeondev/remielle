const remielle = @import("remielle");
const pb = remielle.protobuf.main;

pub fn quickTeamEdit(
    message: Message(pb.QuickTeamEditCsReq),
    properties: Properties.Mutable(.{
        Properties.QuickTeam,
    }),
    sink: Sink,
    response: Response(pb.QuickTeamEditScRsp),
) !void {
    const quick_team_data = message.data.quick_team orelse return response.fail(1);

    for (quick_team_data.quick_team_list.items) |quick_team| {
        const slot = Properties.QuickTeam.Slot.fromInt(quick_team.slot) orelse
            return response.fail(1);

        if (quick_team.avatar_list.items.len > 3 or
            quick_team.buddy_list.items.len > 1) return response.fail(1);

        var meta: Properties.QuickTeam.Meta = .{
            .name = Properties.QuickTeam.Name.fromSlice(quick_team.name) catch
                return response.fail(1),

            .avatar_ids = @splat(.none),
            .buddy_id = .none,
        };

        for (quick_team.avatar_list.items, 0..) |avatar, i|
            meta.avatar_ids[i] = @fromBackingInt(@intCast(avatar.avatar_id));

        if (quick_team.buddy_list.items.len == 1)
            meta.buddy_id = @fromBackingInt(@intCast(quick_team.buddy_list.items[0].buddy_id));

        properties.quick_team.meta[slot.toIndex()] = meta;
    }

    try sink.notify(pb.PlayerSyncScNotify, .{
        .misc = .{ .quick_team = .{
            .quick_team_list = try packers.packQuickTeamList(
                response.allocator,
                &properties.quick_team.meta,
            ),
        } },
    });

    response.set(.init);
}

pub fn quickTeamModName(
    message: Message(pb.QuickTeamModNameCsReq),
    properties: Properties.Mutable(.{
        Properties.QuickTeam,
    }),
    sink: Sink,
    response: Response(pb.QuickTeamModNameScRsp),
) !void {
    const slot = Properties.QuickTeam.Slot.fromInt(message.data.slot) orelse
        return response.fail(1);

    properties.quick_team.meta[slot.toIndex()].name.set(message.data.name) catch
        return response.fail(1);

    try sink.notify(pb.PlayerSyncScNotify, .{
        .misc = .{ .quick_team = .{
            .quick_team_list = try packers.packQuickTeamList(
                response.allocator,
                &properties.quick_team.meta,
            ),
        } },
    });

    response.set(.init);
}

const Sink = handlers.Sink;
const Message = handlers.Message;
const Response = handlers.Response;

const Changes = logic.Changes;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const handlers = @import("../handlers.zig");
const packers = @import("../packers.zig");

const std = @import("std");
