const std = @import("std");
const Io = std.Io;
const Build = std.Build;
const Optimize = std.lang.Optimize;
const ResolvedTarget = std.Build.ResolvedTarget;

pub fn build(b: *Build) void {
    // TODO: use b.dependOn* functionality once it's implemented by the build system.
    b.graph.poisonCache();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const serve_all_exe = b.addExecutable(.{
        .name = "serve-all",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/serve-all.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const steps = .{
        .install = b.getInstallStep(),
        .@"test" = b.step("test", "run the tests"),
        .@"generate-pb" = b.step("generate-pb", "run a struct generation pass on `main.proto`"),
        .@"serve-dp" = b.step("serve-dp", "start the dispatch server"),
        .@"serve-sdk" = b.step("serve-sdk", "start the sdk server"),
        .@"serve-game" = b.step("serve-game", "start the game server"),
        .@"serve-all" = @"serve-all": {
            const run = b.addRunArtifact(serve_all_exe);
            const step = b.step("serve-all", "start dpsv, sdksv, gamesv at once");
            step.dependOn(&run.step);
            break :@"serve-all" run;
        },
        .ctl = b.step("ctl", "execute the rmctl command"),
    };

    const remielle_module = configureRemielleModule(b, .{
        .@"test" = steps.@"test",
    }, .{
        .target = target,
        .optimize = optimize,
    });

    const protobuf_comp = configureProtobufCompilation(b, .{
        .@"generate-pb" = steps.@"generate-pb",
    }, .{
        .optimize = optimize,
    });

    configureDispatchServer(b, .{
        .install = steps.install,
        .@"test" = steps.@"test",
        .@"serve-dp" = steps.@"serve-dp",
        .@"serve-all" = steps.@"serve-all",
    }, .{
        .remielle_module = remielle_module,
        .target = target,
        .optimize = optimize,
    });

    configureSdkServer(b, .{
        .install = steps.install,
        .@"test" = steps.@"test",
        .@"serve-sdk" = steps.@"serve-sdk",
        .@"serve-all" = steps.@"serve-all",
    }, .{
        .remielle_module = remielle_module,
        .target = target,
        .optimize = optimize,
    });

    configureGameServer(b, .{
        .install = steps.install,
        .@"test" = steps.@"test",
        .@"serve-game" = steps.@"serve-game",
        .@"serve-all" = steps.@"serve-all",
    }, .{
        .remielle_module = remielle_module,
        .protobuf_comp = protobuf_comp,
        .target = target,
        .optimize = optimize,
    });

    configureRemielleCtl(b, .{
        .install = steps.install,
        .@"test" = steps.@"test",
        .ctl = steps.ctl,
    }, .{
        .remielle_module = remielle_module,
        .target = target,
        .optimize = optimize,
    });
}

fn configureRemielleModule(
    b: *Build,
    steps: struct {
        @"test": *Build.Step,
    },
    options: struct {
        optimize: Optimize,
        target: ResolvedTarget,
    },
) *Build.Module {
    const remielle = b.addModule(
        "remielle",
        .{
            .root_source_file = b.path("src/remielle.zig"),
            .target = options.target,
            .optimize = options.optimize,
        },
    );

    StaticAsset.addAll(b, remielle, shared_assets);

    const tests = b.addTest(.{ .root_module = remielle });
    steps.@"test".dependOn(&b.addRunArtifact(tests).step);

    return remielle;
}

const stable_protos: []const []const u8 = &.{
    "lib/proto/head.proto",
    "lib/proto/action.proto",
    "lib/proto/persistence.proto",
};

const ProtobufCompilation = struct {
    compile_main_descriptors: *Build.Step,
    compile_stable_definitions: *Build.Step,
};

fn configureProtobufCompilation(
    b: *Build,
    steps: struct {
        @"generate-pb": *Build.Step,
    },
    options: struct {
        optimize: Optimize,
    },
) ProtobufCompilation {
    const @"compile-proto" = b.addExecutable(.{
        .name = "compile-proto",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/build/compile-proto.zig"),
            .target = b.graph.host,
            .optimize = options.optimize,
            .single_threaded = true,
        }),
    });

    const compile_main_structs = b.addUpdateSourceFiles();
    const compile_main_descriptors = b.addUpdateSourceFiles();
    const compile_stable_definitions = b.addUpdateSourceFiles();

    if (b.root.access(b.graph.io, "lib/proto/main.proto", .{ .read = true })) {
        const rmprotoc_descs_pass = b.addRunArtifact(@"compile-proto");
        rmprotoc_descs_pass.expectExitCode(0);
        rmprotoc_descs_pass.addArg("-descriptors");
        rmprotoc_descs_pass.addFileArg(b.path("lib/proto/main.proto"));

        compile_main_descriptors.addCopyFileToSource(
            rmprotoc_descs_pass.captureStdOut(.{ .basename = "pb.main.desc.zig" }),
            "src/protobuf/pb.main.desc.zig",
        );

        const rmprotoc_structs_pass = b.addRunArtifact(@"compile-proto");
        rmprotoc_structs_pass.expectExitCode(0);
        rmprotoc_structs_pass.addArg("-structures");
        rmprotoc_structs_pass.addFileArg(b.path("lib/proto/main.proto"));

        compile_main_structs.addCopyFileToSource(
            rmprotoc_structs_pass.captureStdOut(.{ .basename = "pb.main.zig" }),
            "src/protobuf/pb.main.zig",
        );
    } else |_| {}

    if (filesReadable(b.graph.io, b.root, stable_protos)) {
        const rmprotoc_stable_pass = b.addRunArtifact(@"compile-proto");
        rmprotoc_stable_pass.expectExitCode(0);
        rmprotoc_stable_pass.addArg("-full");

        for (stable_protos) |sub_path|
            rmprotoc_stable_pass.addFileArg(b.path(sub_path));

        compile_stable_definitions.addCopyFileToSource(
            rmprotoc_stable_pass.captureStdOut(.{ .basename = "pb.stable.zig" }),
            "src/protobuf/pb.stable.zig",
        );
    }

    steps.@"generate-pb".dependOn(&compile_main_structs.step);

    return .{
        .compile_main_descriptors = &compile_main_descriptors.step,
        .compile_stable_definitions = &compile_stable_definitions.step,
    };
}

const dpsv_assets: []const StaticAsset = &.{
    .asset("config", "dpsv/config.zon"),
};

fn configureDispatchServer(b: *Build, steps: struct {
    install: *Build.Step,
    @"test": *Build.Step,
    @"serve-dp": *Build.Step,
    @"serve-all": *Build.Step.Run,
}, options: struct {
    remielle_module: *Build.Module,
    target: ResolvedTarget,
    optimize: Optimize,
}) void {
    const module = b.createModule(.{
        .root_source_file = b.path("dpsv/src/main.zig"),
        .imports = &.{
            .{ .name = "remielle", .module = options.remielle_module },
        },
        .target = options.target,
        .optimize = options.optimize,
    });

    StaticAsset.addAll(b, module, dpsv_assets);

    const tests = b.addTest(.{ .root_module = module });
    steps.@"test".dependOn(&b.addRunArtifact(tests).step);

    const exe = b.addExecutable(.{
        .name = "remielle-dpsv",
        .root_module = module,
    });

    const install = b.addInstallArtifact(exe, .{});
    steps.install.dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    steps.@"serve-dp".dependOn(&run.step);

    steps.@"serve-all".addFileArg(exe.getEmittedBin());
}

const sdksv_assets: []const StaticAsset = &.{
    .asset("config", "sdksv/config.zon"),
};

fn configureSdkServer(b: *Build, steps: struct {
    install: *Build.Step,
    @"test": *Build.Step,
    @"serve-sdk": *Build.Step,
    @"serve-all": *Build.Step.Run,
}, options: struct {
    remielle_module: *Build.Module,
    target: ResolvedTarget,
    optimize: Optimize,
}) void {
    const module = b.createModule(.{
        .root_source_file = b.path("sdksv/src/main.zig"),
        .imports = &.{
            .{ .name = "remielle", .module = options.remielle_module },
        },
        .target = options.target,
        .optimize = options.optimize,
    });

    StaticAsset.addAll(b, module, sdksv_assets);

    const tests = b.addTest(.{ .root_module = module });
    steps.@"test".dependOn(&b.addRunArtifact(tests).step);

    const exe = b.addExecutable(.{
        .name = "remielle-sdksv",
        .root_module = module,
    });

    const install = b.addInstallArtifact(exe, .{});
    steps.install.dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    steps.@"serve-sdk".dependOn(&run.step);

    steps.@"serve-all".addFileArg(exe.getEmittedBin());
}

const gamesv_assets: []const StaticAsset = &.{
    .asset("config", "gamesv/config.zon"),
    .asset("initial_xorpad", "gamesv/initial_xorpad.bytes"),
};

fn configureGameServer(b: *Build, steps: struct {
    install: *Build.Step,
    @"test": *Build.Step,
    @"serve-game": *Build.Step,
    @"serve-all": *Build.Step.Run,
}, options: struct {
    remielle_module: *Build.Module,
    protobuf_comp: ProtobufCompilation,
    target: ResolvedTarget,
    optimize: Optimize,
}) void {
    const module = b.createModule(.{
        .root_source_file = b.path("gamesv/src/main.zig"),
        .imports = &.{
            .{ .name = "remielle", .module = options.remielle_module },
        },
        .target = options.target,
        .optimize = options.optimize,
    });

    StaticAsset.addAll(b, module, gamesv_assets);

    const tests = b.addTest(.{ .root_module = module });
    tests.step.dependOn(options.protobuf_comp.compile_main_descriptors);
    tests.step.dependOn(options.protobuf_comp.compile_stable_definitions);
    steps.@"test".dependOn(&b.addRunArtifact(tests).step);

    const exe = b.addExecutable(.{
        .name = "remielle-gamesv",
        .root_module = module,
    });
    exe.step.dependOn(options.protobuf_comp.compile_main_descriptors);
    exe.step.dependOn(options.protobuf_comp.compile_stable_definitions);

    const install = b.addInstallArtifact(exe, .{});
    steps.install.dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    steps.@"serve-game".dependOn(&run.step);

    steps.@"serve-all".addFileArg(exe.getEmittedBin());
}

fn configureRemielleCtl(b: *Build, steps: struct {
    install: *Build.Step,
    @"test": *Build.Step,
    ctl: *Build.Step,
}, options: struct {
    remielle_module: *Build.Module,
    target: ResolvedTarget,
    optimize: Optimize,
}) void {
    const module = b.createModule(.{
        .root_source_file = b.path("rmctl/src/main.zig"),
        .imports = &.{
            .{ .name = "remielle", .module = options.remielle_module },
        },
        .target = options.target,
        .optimize = options.optimize,
    });

    const tests = b.addTest(.{ .root_module = module });
    steps.@"test".dependOn(&b.addRunArtifact(tests).step);

    const exe = b.addExecutable(.{
        .name = "rmctl",
        .root_module = module,
    });

    const install = b.addInstallArtifact(exe, .{});
    steps.install.dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    steps.ctl.dependOn(&run.step);
}

const shared_assets: []const StaticAsset = &.{
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

fn filesReadable(io: Io, dir: Build.Cache.Path, path_list: []const []const u8) bool {
    for (path_list) |sub_path|
        dir.access(io, sub_path, .{ .read = true }) catch return false;

    return true;
}

const StaticAsset = struct {
    import_name: []const u8,
    sub_path: []const u8,

    pub fn asset(import_name: []const u8, sub_path: []const u8) StaticAsset {
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
