const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const assets = remielle.assets;
const templates = remielle.assets.templates;

pub fn enterWorld(
    message: Message(pb.EnterWorldCsReq),
    asset_lookup: *const assets.Lookup,
    properties: Properties.Immutable(.{
        Properties.Hall,
        Properties.BasicInfo,
        Properties.MainCityTime,
    }),
    sink: Sink,
    response: Response(pb.EnterWorldScRsp),
) !void {
    _ = message;

    try sink.notify(pb.EnterSceneScNotify, try packers.packEnterSceneForHall(
        response.allocator,
        asset_lookup,
        properties.hall,
        properties.main_city_time,
        properties.basic_info,
    ));

    response.set(.init);
}

pub fn leaveCurScene(
    message: Message(pb.LeaveCurSceneCsReq),
    asset_lookup: *const assets.Lookup,
    properties: Properties.Immutable(.{
        Properties.Hall,
        Properties.BasicInfo,
        Properties.MainCityTime,
    }),
    sink: Sink,
    response: Response(pb.LeaveCurSceneScRsp),
) !void {
    _ = message;

    try sink.notify(pb.EnterSceneScNotify, try packers.packEnterSceneForHall(
        response.allocator,
        asset_lookup,
        properties.hall,
        properties.main_city_time,
        properties.basic_info,
    ));

    response.set(.init);
}

pub fn enterSection(
    message: Message(pb.EnterSectionCsReq),
    asset_lookup: *const assets.Lookup,
    properties: Properties.Mutable(.{
        Properties.Hall,
        Properties.BasicInfo,
        Properties.MainCityTime,
    }),
    sink: Sink,
    response: Response(pb.EnterSectionScRsp),
) !void {
    const section_id = std.enums.fromInt(
        templates.section_config.Id,
        message.data.section_id,
    ) orelse return response.fail(1);

    const position: Properties.Hall.Position = Properties.Hall.Position.fromId(
        message.data.transform_id,
    ) orelse .init;

    properties.hall.section_id = section_id;
    properties.hall.position = position;

    try sink.notify(pb.EnterSceneScNotify, try packers.packEnterSceneForHall(
        response.allocator,
        asset_lookup,
        properties.hall,
        properties.main_city_time,
        properties.basic_info,
    ));

    response.set(.init);
}

pub fn interactWithUnit(
    message: Message(pb.InteractWithUnitCsReq),
    properties: Properties.Immutable(.{
        Properties.Hall,
    }),
    sink: Sink,
    response: Response(pb.InteractWithUnitScRsp),
) !void {
    const interact_index: u32 = @intCast(std.mem.findScalar(
        u32,
        assets.graphs.interacts.ids,
        @bitCast(message.data.interact_id),
    ) orelse
        return response.fail(1));

    try sink.notify(
        pb.SectionEventScNotify,
        try packers.packSectionEventByInteract(
            response.allocator,
            properties.hall,
            interact_index,
        ),
    );

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
    properties: Properties.Mutable(.{
        Properties.Hall,
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
        properties.hall.position = Properties.Hall.Position.fromVectors(
            transform.position.items,
            transform.rotation.items,
        ) orelse return response.fail(1);
    };

    response.set(.init);
}

pub fn modMainCityTime(
    message: Message(pb.ModMainCityTimeCsReq),
    properties: logic.Properties.Mutable(.{
        Properties.Hall,
        Properties.MainCityTime,
    }),
    sink: Sink,
    response: Response(pb.ModMainCityTimeScRsp),
) !void {
    const next_time_period = std.enums.fromInt(
        Properties.MainCityTime.TimePeriod,
        message.data.time_period,
    ) orelse
        return response.fail(1);

    properties.main_city_time.time_in_minutes = next_time_period.toTimeInMinutes();

    if (next_time_period.isNextDayOf(.fromTimeInMinutes(properties.main_city_time.time_in_minutes)))
        properties.main_city_time.day_of_week = properties.main_city_time.day_of_week.nextDay();

    try sink.notify(pb.HallRefreshScNotify, packers.packHallRefreshMinimal(
        properties.hall,
        properties.main_city_time,
        .{ .force = true },
    ));

    response.set(.init);
}

const Sink = handlers.Sink;
const Message = handlers.Message;
const Response = handlers.Response;

const Changes = logic.Changes;
const Properties = logic.Properties;

const packers = @import("../packers.zig");
const logic = @import("../../logic.zig");
const handlers = @import("../handlers.zig");

const std = @import("std");
