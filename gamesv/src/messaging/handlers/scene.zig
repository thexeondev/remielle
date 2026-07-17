const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const assets = remielle.assets;
const templates = remielle.assets.templates;

pub fn enterWorld(
    message: Message(pb.EnterWorldCsReq),
    properties: Properties.Immutable(.{
        Properties.Hall,
    }),
    changes: Changes.Builder(.{
        Changes.GameMode,
    }),
    response: Response(pb.EnterWorldScRsp),
) !void {
    _ = message;

    const mode_switch: Changes.GameMode = .{ .hall = .{
        .section_id = properties.hall.section_id,
        .position = properties.hall.position,
    } };

    changes.insert(mode_switch);
    response.set(.init);
}

pub fn leaveCurScene(
    message: Message(pb.LeaveCurSceneCsReq),
    properties: Properties.Immutable(.{
        Properties.Hall,
    }),
    changes: Changes.Builder(.{
        Changes.GameMode,
    }),
    response: Response(pb.LeaveCurSceneScRsp),
) !void {
    _ = message;

    const mode_switch: Changes.GameMode = .{ .hall = .{
        .section_id = properties.hall.section_id,
        .position = properties.hall.position,
    } };

    changes.insert(mode_switch);
    response.set(.init);
}

pub fn enterSection(
    message: Message(pb.EnterSectionCsReq),
    changes: Changes.Builder(.{
        Changes.GameMode,
    }),
    response: Response(pb.EnterSectionScRsp),
) !void {
    const section_id = std.enums.fromInt(
        templates.section_config.Id,
        message.data.section_id,
    ) orelse return response.fail(1);

    const position: Properties.Hall.Position = Properties.Hall.Position.fromId(
        message.data.transform_id,
    ) orelse .init;

    const mode_switch: Changes.GameMode = .{ .hall = .{
        .section_id = section_id,
        .position = position,
    } };

    changes.insert(mode_switch);
    response.set(.init);
}

pub fn interactWithUnit(
    message: Message(pb.InteractWithUnitCsReq),
    changes: Changes.Builder(.{
        Changes.NpcInteraction,
    }),
    response: Response(pb.InteractWithUnitScRsp),
) !void {
    const interaction: Changes.NpcInteraction = .{
        .interact_index = @intCast(std.mem.findScalar(
            u32,
            assets.graphs.interacts.ids,
            @bitCast(message.data.interact_id),
        ) orelse
            return response.fail(1)),
    };

    changes.insert(interaction);
    response.set(.init);
}

pub fn enterSectionComplete(
    message: Message(pb.EnterSectionCompleteCsReq),
    response: Response(pb.EnterSectionCompleteScRsp),
) !void {
    _ = message;
    response.set(.init);
}

pub fn sectionRefresh(
    message: Message(pb.SectionRefreshCsReq),
    response: Response(pb.SectionRefreshScRsp),
) !void {
    _ = message;
    response.set(.init);
}

pub fn savePosInMainCity(
    message: Message(pb.SavePosInMainCityCsReq),
    properties: Properties.Immutable(.{
        Properties.Hall,
    }),
    changes: Changes.Builder(.{
        Changes.PosInMainCity,
    }),
    response: Response(pb.SavePosInMainCityScRsp),
) !void {
    if (!message.data.real_save) return response.set(.init);

    const section_id = std.enums.fromInt(templates.section_config.Id, message.data.section_id) orelse
        return response.fail(1);

    // The client might send a request when a section switch is already pending,
    // it'll have previous section_id in it. Simply ignore such requests for now,
    // later, maybe there will be a need to store positions for each section.
    if (message.data.position) |transform| if (properties.hall.section_id == section_id) {
        const pos_in_main_city: Changes.PosInMainCity = .{
            .new_position = Properties.Hall.Position.fromVectors(
                transform.position.items,
                transform.rotation.items,
            ) orelse return response.fail(1),
        };

        changes.insert(pos_in_main_city);
    };

    response.set(.init);
}

pub fn modMainCityTime(
    message: Message(pb.ModMainCityTimeCsReq),
    properties: logic.Properties.Mutable(.{
        Properties.MainCityTime,
    }),
    changes: Changes.Builder(.{
        Changes.MainCityTime,
    }),
    response: Response(pb.ModMainCityTimeScRsp),
) !void {
    const next_time_period = std.enums.fromInt(Properties.MainCityTime.TimePeriod, message.data.time_period) orelse
        return response.fail(1);

    var main_city_time: Changes.MainCityTime = .{
        .time_in_minutes = next_time_period.toTimeInMinutes(),
        .day_of_week = properties.main_city_time.day_of_week,
    };

    if (next_time_period.isNextDayOf(.fromTimeInMinutes(properties.main_city_time.time_in_minutes)))
        main_city_time.day_of_week = main_city_time.day_of_week.nextDay();

    changes.insert(main_city_time);
    response.set(.init);
}

const Message = handlers.Message;
const Response = handlers.Response;

const Changes = logic.Changes;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const handlers = @import("../handlers.zig");

const std = @import("std");
