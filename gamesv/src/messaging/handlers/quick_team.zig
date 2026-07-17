const remielle = @import("remielle");
const pb = remielle.protobuf.main;

pub fn quickTeamEdit(
    message: Message(pb.QuickTeamEditCsReq),
    changes: Changes.Builder(.{
        Changes.QuickTeam,
    }),
    response: Response(pb.QuickTeamEditScRsp),
) !void {
    const quick_team_data = message.data.quick_team orelse return response.fail(1);
    var quick_teams: std.ArrayList(Changes.QuickTeam) = try .initCapacity(changes.allocator, quick_team_data.quick_team_list.items.len);

    for (quick_team_data.quick_team_list.items) |quick_team| {
        if (quick_team.avatar_list.items.len > 3 or
            quick_team.buddy_list.items.len > 1) return response.fail(1);

        var meta: Properties.QuickTeam.Meta = .{
            .name = Properties.QuickTeam.Name.fromSlice(quick_team.name) catch return response.fail(1),
            .avatar_ids = @splat(.none),
            .buddy_id = .none,
        };

        for (quick_team.avatar_list.items, 0..) |avatar, i| meta.avatar_ids[i] = @enumFromInt(avatar.avatar_id);
        if (quick_team.buddy_list.items.len == 1) meta.buddy_id = @enumFromInt(quick_team.buddy_list.items[0].buddy_id);

        quick_teams.appendAssumeCapacity(.{
            .slot = Properties.QuickTeam.Slot.fromInt(quick_team.slot) orelse return response.fail(1),
            .meta = meta,
        });
    }

    changes.insert(quick_teams.items);
    response.set(.init);
}

pub fn quickTeamModName(
    message: Message(pb.QuickTeamModNameCsReq),
    properties: Properties.Immutable(.{
        Properties.QuickTeam,
    }),
    changes: Changes.Builder(.{
        Changes.QuickTeam,
    }),
    response: Response(pb.QuickTeamModNameScRsp),
) !void {
    var quick_teams = try changes.allocator.alloc(Changes.QuickTeam, 1);
    quick_teams[0].slot = Properties.QuickTeam.Slot.fromInt(message.data.slot) orelse return response.fail(1);
    quick_teams[0].meta = properties.quick_team.meta[quick_teams[0].slot.toIndex()];
    quick_teams[0].meta.name.set(message.data.name) catch return response.fail(1);

    changes.insert(quick_teams);
    response.set(.init);
}

const Message = handlers.Message;
const Response = handlers.Response;

const Changes = logic.Changes;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const handlers = @import("../handlers.zig");

const std = @import("std");
