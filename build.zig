const stable_protos: []const []const u8 = &.{
    "rmpb/cs_proto/head.proto",
    "rmpb/cs_proto/action.proto",
    "rmpb/cs_proto/persistence.proto",
};

pub fn build(b: *Build) void {
    const rmio = b.createModule(.{ .root_source_file = b.path("rmio/src/root.zig") });
    const rmnet = b.createModule(.{ .root_source_file = b.path("rmnet/src/root.zig") });
    const rmmem = b.createModule(.{ .root_source_file = b.path("rmmem/src/root.zig") });
    const rmcli = b.createModule(.{ .root_source_file = b.path("rmcli/src/root.zig") });
    const rmcrypt = b.createModule(.{ .root_source_file = b.path("rmcrypt/src/root.zig") });

    const rmpb = b.createModule(.{ .root_source_file = b.path("rmpb/src/root.zig") });

    const host = b.graph.host;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const io = b.graph.io;
    const cwd: Io.Dir = .cwd();

    const rmprotoc = b.addExecutable(.{
        .name = "rmprotoc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("rmpb/compiler/main.zig"),
            .target = host,
            .optimize = optimize,
            .single_threaded = true,
        }),
    });

    const compile_main_structs = b.addUpdateSourceFiles();
    const compile_main_descriptors = b.addUpdateSourceFiles();
    const compile_stable_definitions = b.addUpdateSourceFiles();

    if (cwd.access(io, "rmpb/cs_proto/main.proto", .{ .read = true })) {
        const rmprotoc_descs_pass = b.addRunArtifact(rmprotoc);
        rmprotoc_descs_pass.expectExitCode(0);
        rmprotoc_descs_pass.addArg("-descriptors");
        rmprotoc_descs_pass.addFileArg(b.path("rmpb/cs_proto/main.proto"));

        compile_main_descriptors.addCopyFileToSource(
            rmprotoc_descs_pass.captureStdOut(.{ .basename = "pb.main.desc.zig" }),
            "rmpb/src/pb.main.desc.zig",
        );

        const rmprotoc_structs_pass = b.addRunArtifact(rmprotoc);
        rmprotoc_structs_pass.expectExitCode(0);
        rmprotoc_structs_pass.addArg("-structures");
        rmprotoc_structs_pass.addFileArg(b.path("rmpb/cs_proto/main.proto"));

        compile_main_structs.addCopyFileToSource(
            rmprotoc_structs_pass.captureStdOut(.{ .basename = "pb.main.zig" }),
            "rmpb/src/pb.main.zig",
        );
    } else |_| {}

    if (filesReadable(io, cwd, stable_protos)) {
        const rmprotoc_stable_pass = b.addRunArtifact(rmprotoc);
        rmprotoc_stable_pass.expectExitCode(0);
        rmprotoc_stable_pass.addArg("-full");

        for (stable_protos) |sub_path|
            rmprotoc_stable_pass.addFileArg(b.path(sub_path));

        compile_stable_definitions.addCopyFileToSource(
            rmprotoc_stable_pass.captureStdOut(.{ .basename = "pb.stable.zig" }),
            "rmpb/src/pb.stable.zig",
        );
    }

    const dpsv = b.addExecutable(.{
        .name = "remielle-dpsv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("dpsv/src/main.zig"),
            .imports = &.{
                .{ .name = "rmio", .module = rmio },
                .{ .name = "rmcli", .module = rmcli },
                .{ .name = "rmcrypt", .module = rmcrypt },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    StaticAsset.addAll(b, dpsv.root_module, dpsv_assets);

    const sdksv = b.addExecutable(.{
        .name = "remielle-sdksv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sdksv/src/main.zig"),
            .imports = &.{
                .{ .name = "rmio", .module = rmio },
                .{ .name = "rmmem", .module = rmmem },
                .{ .name = "rmcli", .module = rmcli },
                .{ .name = "rmcrypt", .module = rmcrypt },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    StaticAsset.addAll(b, sdksv.root_module, sdksv_assets);

    const gamesv = b.addExecutable(.{
        .name = "remielle-gamesv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("gamesv/src/main.zig"),
            .imports = &.{
                .{ .name = "rmio", .module = rmio },
                .{ .name = "rmnet", .module = rmnet },
                .{ .name = "rmmem", .module = rmmem },
                .{ .name = "rmcli", .module = rmcli },
                .{ .name = "rmcrypt", .module = rmcrypt },
                .{ .name = "rmpb", .module = rmpb },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    StaticAsset.addAll(b, gamesv.root_module, gamesv_assets);
    gamesv.step.dependOn(&compile_main_descriptors.step);
    gamesv.step.dependOn(&compile_stable_definitions.step);

    const rmctl = b.addExecutable(.{
        .name = "rmctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("rmctl/src/main.zig"),
            .imports = &.{
                .{ .name = "rmio", .module = rmio },
                .{ .name = "rmnet", .module = rmnet },
            },
            .target = target,
            .optimize = optimize,
        }),
    });

    StaticAsset.addAll(b, rmctl.root_module, rmctl_assets);

    b.step(
        "pb",
        "run a struct generation pass on `main.proto`",
    ).dependOn(&compile_main_structs.step);

    const ctl = b.addRunArtifact(rmctl);
    const serve_dp = b.addRunArtifact(dpsv);
    const serve_sdk = b.addRunArtifact(sdksv);
    const serve_game = b.addRunArtifact(gamesv);

    if (b.args) |args| {
        ctl.addArgs(args);
        serve_dp.addArgs(args);
        serve_sdk.addArgs(args);
        serve_game.addArgs(args);
    }

    b.step(
        "ctl",
        "execute the rmctl command",
    ).dependOn(&ctl.step);

    b.step(
        "serve-dp",
        "start the dispatch server",
    ).dependOn(&serve_dp.step);

    b.step(
        "serve-sdk",
        "start the sdk server",
    ).dependOn(&serve_sdk.step);

    b.step(
        "serve-game",
        "start the game server",
    ).dependOn(&serve_game.step);

    b.installArtifact(dpsv);
    b.installArtifact(sdksv);
    b.installArtifact(gamesv);

    const serve_all_exe = b.addExecutable(.{
        .name = "serve-all",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/serve-all.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const serve_all = b.addRunArtifact(serve_all_exe);
    serve_all.addFileArg(dpsv.getEmittedBin());
    serve_all.addFileArg(sdksv.getEmittedBin());
    serve_all.addFileArg(gamesv.getEmittedBin());

    b.step(
        "serve-all",
        "start dpsv, sdksv, gamesv at once",
    ).dependOn(&serve_all.step);

    const tests = b.step("test", "run unit tests");
    const rmio_tests = b.addTest(.{
        .name = "rmio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("rmio/src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    tests.dependOn(&b.addRunArtifact(rmio_tests).step);
}

const gamesv_assets: []const StaticAsset = &.{
    .asset("config", "gamesv/config.zon"),
    .asset("initial_xorpad", "gamesv/initial_xorpad.bytes"),

    // Filecfg
    .asset("AvatarBaseTemplateTb", "assets/filecfg/AvatarBaseTemplateTb.zon"),
    .asset("BuddyBaseTemplateTb", "assets/filecfg/BuddyBaseTemplateTb.zon"),
    .asset("AvatarSkinBaseTemplateTb", "assets/filecfg/AvatarSkinBaseTemplateTb.zon"),
    .asset("UnlockConfigTemplateTb", "assets/filecfg/UnlockConfigTemplateTb.zon"),
    .asset("PostGirlConfigTemplateTb", "assets/filecfg/PostGirlConfigTemplateTb.zon"),
    .asset("SectionConfigTemplateTb", "assets/filecfg/SectionConfigTemplateTb.zon"),
    .asset("YorozuyaLevelTemplateTb", "assets/filecfg/YorozuyaLevelTemplateTb.zon"),
    .asset("TrainingQuestTemplateTb", "assets/filecfg/TrainingQuestTemplateTb.zon"),
    .asset("WeaponTemplateTb", "assets/filecfg/WeaponTemplateTb.zon"),
    .asset("UrbanAreaMapTemplateTb", "assets/filecfg/UrbanAreaMapTemplateTb.zon"),
    .asset("UrbanAreaMapGroupTemplateTb", "assets/filecfg/UrbanAreaMapGroupTemplateTb.zon"),
    .asset("TeleportConfigTemplateTb", "assets/filecfg/TeleportConfigTemplateTb.zon"),
    .asset("EquipmentTemplateTb", "assets/filecfg/EquipmentTemplateTb.zon"),
    .asset("ZoneInfoTemplateTb", "assets/filecfg/ZoneInfoTemplateTb.zon"),
    .asset("QuestConfigTemplateTb", "assets/filecfg/QuestConfigTemplateTb.zon"),
    .asset("HadalZoneQuestTemplateTb", "assets/filecfg/HadalZoneQuestTemplateTb.zon"),
    .asset("AvatarBattleTemplateTb", "assets/filecfg/AvatarBattleTemplateTb.zon"),
    .asset("AvatarLevelAdvanceTemplateTb", "assets/filecfg/AvatarLevelAdvanceTemplateTb.zon"),
    .asset("AvatarPassiveSkillTemplateTb", "assets/filecfg/AvatarPassiveSkillTemplateTb.zon"),
    .asset("WeaponLevelTemplateTb", "assets/filecfg/WeaponLevelTemplateTb.zon"),
    .asset("WeaponStarTemplateTb", "assets/filecfg/WeaponStarTemplateTb.zon"),
    .asset("EquipmentLevelTemplateTb", "assets/filecfg/EquipmentLevelTemplateTb.zon"),
    .asset("EquipmentSuitTemplateTb", "assets/filecfg/EquipmentSuitTemplateTb.zon"),
    .asset("AvatarSpecialAwakenTemplateTb", "assets/filecfg/AvatarSpecialAwakenTemplateTb.zon"),

    // Binary-packed
    .asset("main_city_object_template_tb.remi", "assets/bincfg/main_city_object_template_tb.remi"),
    .asset("main_city.remi", "assets/graphs/main_city.remi"),
    .asset("interacts.remi", "assets/graphs/interacts.remi"),
};

const dpsv_assets: []const StaticAsset = &.{
    .asset("config", "dpsv/config.zon"),
};

const sdksv_assets: []const StaticAsset = &.{
    .asset("config", "sdksv/config.zon"),
};

const rmctl_assets: []const StaticAsset = &.{
    .asset("EquipmentSuitTemplateTb", "assets/filecfg/EquipmentSuitTemplateTb.zon"),
};

fn filesReadable(io: Io, dir: Io.Dir, path_list: []const []const u8) bool {
    for (path_list) |sub_path|
        dir.access(io, sub_path, .{ .read = true }) catch return false;

    return true;
}

const StaticAsset = struct {
    import_name: []const u8,
    sub_path: []const u8,

    pub inline fn asset(import_name: []const u8, sub_path: []const u8) StaticAsset {
        return .{ .import_name = import_name, .sub_path = sub_path };
    }

    pub fn addAll(b: *Build, module: *Build.Module, assets: []const StaticAsset) void {
        for (assets) |a|
            module.addAnonymousImport(
                a.import_name,
                .{ .root_source_file = b.path(a.sub_path) },
            );
    }
};

const Io = std.Io;
const Build = std.Build;

const std = @import("std");
