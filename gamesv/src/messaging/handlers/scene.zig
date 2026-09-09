const std = @import("std");

const remielle = @import("remielle");
const pb = remielle.protobuf.main;
const assets = remielle.assets;
const templates = remielle.assets.templates;

const logic = @import("../../logic.zig");
const Properties = logic.Properties;

const handlers = @import("../handlers.zig");
const Scope = handlers.Scope;

const packers = @import("../packers.zig");

pub fn EnterWorldCsReq(scope: *Scope) !void {
    try scope.sink.notify(pb.EnterSceneScNotify, try packers.packEnterSceneForHall(
        scope.sink.allocator,
        scope.asset_lookup,
        &scope.properties.hall,
        &scope.properties.main_city_time,
        &scope.properties.basic_info,
    ));

    try scope.sink.respond(pb.EnterWorldScRsp, .init);
}

pub fn LeaveCurSceneCsReq(scope: *Scope) !void {
    try scope.sink.notify(pb.EnterSceneScNotify, try packers.packEnterSceneForHall(
        scope.sink.allocator,
        scope.asset_lookup,
        &scope.properties.hall,
        &scope.properties.main_city_time,
        &scope.properties.basic_info,
    ));

    try scope.sink.respond(pb.LeaveCurSceneScRsp, .init);
}

pub fn EnterSectionCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.EnterSectionCsReq);

    const section_id = std.enums.fromInt(
        templates.section_config.Id,
        request.section_id,
    ) orelse return try scope.sink.respond(pb.EnterSectionScRsp, .{ .retcode = 1 });

    const position: Properties.Hall.Position = Properties.Hall.Position.fromId(
        request.transform_id,
    ) orelse .init;

    scope.properties.hall.section_id = section_id;
    scope.properties.hall.position = position;

    try scope.sink.notify(pb.EnterSceneScNotify, try packers.packEnterSceneForHall(
        scope.sink.allocator,
        scope.asset_lookup,
        &scope.properties.hall,
        &scope.properties.main_city_time,
        &scope.properties.basic_info,
    ));

    try scope.sink.respond(pb.EnterSectionScRsp, .init);
}

pub fn InteractWithUnitCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.InteractWithUnitCsReq);

    const interact_index: u32 = @intCast(std.mem.findScalar(
        u32,
        assets.graphs.interacts.ids,
        @bitCast(request.interact_id),
    ) orelse
        return try scope.sink.respond(pb.InteractWithUnitScRsp, .{ .retcode = 1 }));

    try scope.sink.notify(
        pb.SectionEventScNotify,
        try packers.packSectionEventByInteract(
            scope.sink.allocator,
            &scope.properties.hall,
            interact_index,
        ),
    );

    try scope.sink.respond(pb.InteractWithUnitScRsp, .init);
}

pub fn EnterSectionCompleteCsReq(scope: *Scope) !void {
    try scope.sink.respond(pb.EnterSectionCompleteScRsp, .init);
}

pub fn SectionRefreshCsReq(scope: *Scope) !void {
    try scope.sink.respond(pb.SectionRefreshScRsp, .init);
}

pub fn SavePosInMainCityCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.SavePosInMainCityCsReq);
    if (!request.real_save)
        return try scope.sink.respond(pb.SavePosInMainCityScRsp, .init);

    const section_id = std.enums.fromInt(templates.section_config.Id, request.section_id) orelse
        return try scope.sink.respond(pb.SavePosInMainCityScRsp, .{ .retcode = 1 });

    // The client might send a request when a section switch is already pending,
    // it'll have previous section_id in it. Simply ignore such requests for now,
    // later, maybe there will be a need to store positions for each section.
    if (request.position) |transform| if (scope.properties.hall.section_id == section_id) {
        scope.properties.hall.position = Properties.Hall.Position.fromVectors(
            transform.position.items,
            transform.rotation.items,
        ) orelse return try scope.sink.respond(pb.SavePosInMainCityScRsp, .{ .retcode = 1 });
    };

    return try scope.sink.respond(pb.SavePosInMainCityScRsp, .init);
}

pub fn ModMainCityTimeCsReq(scope: *Scope) !void {
    const request = try scope.source.take(pb.ModMainCityTimeCsReq);

    const next_time_period = std.enums.fromInt(
        Properties.MainCityTime.TimePeriod,
        request.time_period,
    ) orelse
        return try scope.sink.respond(pb.ModMainCityTimeScRsp, .init);

    scope.properties.main_city_time.time_in_minutes = next_time_period.toTimeInMinutes();

    if (next_time_period.isNextDayOf(.fromTimeInMinutes(scope.properties.main_city_time.time_in_minutes)))
        scope.properties.main_city_time.day_of_week =
            scope.properties.main_city_time.day_of_week.nextDay();

    try scope.sink.notify(pb.HallRefreshScNotify, packers.packHallRefreshMinimal(
        &scope.properties.hall,
        &scope.properties.main_city_time,
        .{ .force = true },
    ));

    try scope.sink.respond(pb.ModMainCityTimeScRsp, .init);
}
