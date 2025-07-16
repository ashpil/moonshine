const std = @import("std");

// TODO: useful error messages on missing system deps

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    // packages/libraries we'll need below
    const vulkan = makeVulkanModule(b);
    const glfw = try makeGlfwModule(b, target);
    const imgui = makeDCImguiModule(b, glfw, target);
    const tinyexr = makeTinyExrModule(b, target);
    const wuffs = makeWuffsModule(b, target);
    const zgltf = makeZgltfModule(b, target);
    const tracy = makeTracyModule(b, target);
    const shader_source = b.createModule(.{
        .root_source_file = b.path("src/lib/core/shader_source.zig"),
    });
    const hrtsystem_shaders = makeHrtsystemShaders(b, shader_source);
    const default_engine_options = EngineOptions.fromCli(b);

    var compiles = std.array_list.Managed(*std.Build.Step.Compile).init(b.allocator);

    // TODO: make custom test runner parallel + share some state across tests
    try compiles.append(blk: {
        var engine_options = default_engine_options;
        engine_options.vk_validation = .panic;
        engine_options.window = false;
        engine_options.gui = false;
        engine_options.shader_source_type = .embed;
        const engine = makeEngineModule(b, engine_options, shader_source, hrtsystem_shaders, vulkan, zgltf, tinyexr, wuffs, glfw, imgui, tracy);

        const tests = b.addTest(.{
            .name = "gpu-tests",
            .test_runner = .{
                .path = b.path("src/lib/test_runner.zig"),
                .mode = .simple,
            },
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib/tests.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &[_]std.Build.Module.Import {
                    .{ .name = "vulkan", .module = vulkan },
                    .{ .name = "engine", .module = engine },
                },
            })
        });

        break :blk tests;
    });

    try compiles.append(blk: {
        var engine_options = default_engine_options;
        engine_options.shader_source_type = .embed;
        const engine = makeEngineModule(b, engine_options, shader_source, hrtsystem_shaders, vulkan, zgltf, tinyexr, wuffs, glfw, imgui, tracy);
        engine.resolved_target = target;
        engine.optimize = optimize;

        const tests = b.addTest(.{
            .name = "cpu-tests",
            .root_module = engine,
        });

        break :blk tests;
    });

    // online exe
    try compiles.append(blk: {
        var engine_options = default_engine_options;
        engine_options.vk_metrics = true;
        engine_options.shader_source_type = if (target.result.os.tag == .linux) .load else .embed; // hot reload only works on linux atm
        const engine = makeEngineModule(b, engine_options, shader_source, hrtsystem_shaders, vulkan, zgltf, tinyexr, wuffs, glfw, imgui, tracy);
        const exe = b.addExecutable(.{
            .name = "online",
            .use_llvm = true, // seems to be some compiler bug as of 0.15.1 that prevents online from compiling
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bin/online/online.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &[_]std.Build.Module.Import {
                    .{ .name = "vulkan", .module = vulkan },
                    .{ .name = "engine", .module = engine },
                    .{ .name = "shaders", .module = makeShadersModule(b, shader_source, &[_]ShaderImport {
                        ShaderImport { .shader = Shader { .language = .hlsl, .path = "src/bin/online/input.hlsl", }, .name = "input" },
                        ShaderImport { .shader = Shader { .language = .hlsl, .path = "src/bin/online/post_process.hlsl" }, .name = "post_process", },
                    }) },
                },
            }),
        });

        break :blk exe;
    });

    // offline exe
    try compiles.append(blk: {
        var engine_options = default_engine_options;
        engine_options.window = false;
        engine_options.gui = false;
        engine_options.shader_source_type = .embed;
        const engine = makeEngineModule(b, engine_options, shader_source, hrtsystem_shaders, vulkan, zgltf, tinyexr, wuffs, glfw, imgui, tracy);
        const exe = b.addExecutable(.{
            .name = "offline",
            .use_llvm = true, // native seems way slower and doesn't work with tracy
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bin/offline.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &[_]std.Build.Module.Import {
                    .{ .name = "vulkan", .module = vulkan },
                    .{ .name = "engine", .module = engine },
                },
            }),
        });

        break :blk exe;
    });

    // hydra shared lib
    if (target.result.os.tag == .linux) {
        var engine_options = default_engine_options;
        engine_options.window = false;
        engine_options.gui = false;
        engine_options.shader_source_type = if (target.result.os.tag == .linux) .load else .embed; // hot reload only works on linux atm
        const engine = makeEngineModule(b, engine_options, shader_source, hrtsystem_shaders, vulkan, zgltf, tinyexr, wuffs, glfw, imgui, tracy);

        // once https://github.com/ziglang/zig/issues/9698 lands
        // wont need to make own header
        const zig_lib = b.addLibrary(.{
            .name = "moonshine",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bin/hydra/hydra.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &[_]std.Build.Module.Import {
                    .{ .name = "vulkan", .module = vulkan },
                    .{ .name = "engine", .module = engine },
                },
                .pic = true,
                .link_libc = true,
            }),
        });
        try compiles.append(zig_lib);

        const lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "hdMoonshine",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });
        lib.root_module.addCSourceFiles(.{
           .files = &.{
                "hydra/rendererPlugin.cpp",
                "hydra/renderDelegate.cpp",
                "hydra/renderPass.cpp",
                "hydra/renderBuffer.cpp",
                "hydra/mesh.cpp",
                "hydra/camera.cpp",
                "hydra/instancer.cpp",
                "hydra/material.cpp",
            },
            .flags = &.{
                "-DTBB_USE_DEBUG=0",
                "-DARCH_HAS_GNU_STL_EXTENSIONS",
            }
        });
        lib.root_module.linkLibrary(zig_lib);

        // options
        const usd_dir = b.option([]const u8, "usd-path", "Where your USD SDK is installed.") orelse "../USD";
        const tbb_dir = b.option([]const u8, "tbb-path", "Where your TBB is installed.");
        const usd_monolithic = b.option(bool, "usd-monolithic", "Whether USD was built monolithically.") orelse false;

        // link against usd produced libraries
        lib.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ usd_dir, "lib/" }) });
        if (usd_monolithic) {
            lib.root_module.linkSystemLibrary("usd_ms", .{});
        } else {
            lib.root_module.linkSystemLibrary("usd_hd", .{});
            lib.root_module.linkSystemLibrary("usd_sdr", .{});
            lib.root_module.linkSystemLibrary("usd_hio", .{});
        }

        // include headers necessary for usd
        lib.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ usd_dir, "include/" }) });
        if (tbb_dir) |dir| lib.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dir, "include/" }) });

        // might need python headers if USD built with python support
        {
            var out_code: u8 = undefined;
            const paths =  b.runAllowFail(&.{ "python3-config", "--includes" }, &out_code, .inherit) catch b.runAllowFail(&.{ "python-config", "--includes" }, &out_code, .inherit) catch "";
            if (paths.len != 0) {
                var iter = std.mem.splitScalar(u8, paths, ' ');
                while (iter.next()) |include_dir| lib.root_module.addSystemIncludePath(.{ .cwd_relative = include_dir[2..] });
            }
        }

        // deal with the fact that USD is not (supposed to be) compiled with clang
        // make nicer once https://github.com/ziglang/zig/issues/3936
        {
            // link against stdlibc++
            lib.root_module.addObjectFile(.{ .cwd_relative = std.mem.trim(u8, b.run(&.{ "g++", "-print-file-name=libstdc++.so" }), &std.ascii.whitespace) });

            // need stdlibc++ include directories
            // i've had to do some arcane magic to figure out what to do here,
            // and i'm not even convinced it'll work on any system other than mine
            var first = true;
            var iter = std.mem.splitScalar(u8, runAllowFailStderr(b, &.{ "g++", "-E", "-Wp,-v", "-xc++", "/dev/null" }) catch "", '\n');
            while (iter.next()) |include_dir| if (include_dir.len > 0 and include_dir[0] == ' ') {
                if (first) {
                    lib.root_module.addIncludePath(.{ .cwd_relative = include_dir[1..] });
                } else {
                    lib.root_module.addSystemIncludePath(.{ .cwd_relative = include_dir[1..] });
                }
                first = false;
            };
        }

        const step = b.step("hydra", "Build hydra delegate");

        const install = b.addInstallArtifact(lib, .{ .dest_sub_path = "hdMoonshine.so" });
        step.dependOn(&install.step);

        const write_pluginfo_json = b.addWriteFiles();
        const pluginfo_file = write_pluginfo_json.add("plugInfo.json",
            \\{
            \\    "Plugins": [
            \\        {
            \\            "Info": {
            \\                "Types": {
            \\                    "HdMoonshinePlugin": {
            \\                        "bases": [
            \\                            "HdRendererPlugin"
            \\                        ],
            \\                        "displayName": "Moonshine",
            \\                        "priority": 1
            \\                    }
            \\                }
            \\            },
            \\            "LibraryPath": "hdMoonshine.so",
            \\            "Name": "HdMoonshine",
            \\            "ResourcePath": ".",
            \\            "Root": ".",
            \\            "Type": "library"
            \\        }
            \\    ]
            \\}
        );
        const install_pluginfo_json = b.addInstallLibFile(pluginfo_file, "plugInfo.json");
        step.dependOn(&install_pluginfo_json.step);
    }

    // create run step for all exes
    for (compiles.items) |exe| {
        if (exe.kind == .lib or exe.kind == .obj) continue;
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);

        const step_name = b.fmt("run-{s}", .{ exe.name });
        const step_description = b.fmt("Run {s}", .{ exe.name });
        const step = b.step(step_name, step_description);
        step.dependOn(&run.step);
    }

    // create install step for all compiles
    for (compiles.items) |compile| {
        const install = b.addInstallArtifact(compile, .{});

        const step_name = b.fmt("install-{s}", .{ compile.name });
        const step_description = b.fmt("Install {s}", .{ compile.name });
        const step = b.step(step_name, step_description);
        step.dependOn(&install.step);
    }

    // create check step that type-checks all compiles
    // probably does a bit more atm but what can you do
    const check_step = b.step("check", "Type check all");
    for (compiles.items) |compile| {
        check_step.dependOn(&compile.step);
    }
}

fn runAllowFailStderr(self: *std.Build, argv: []const []const u8) ![]u8 {
    std.debug.assert(argv.len != 0);

    const graph = self.graph;
    const io = graph.io;

    const max_output_size = 400 * 1024;
    try std.Build.Step.handleVerbose2(self, .inherit, &graph.environ_map, argv);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &graph.environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });

    var stderr_reader = child.stderr.?.readerStreaming(io, &.{});
    const stderr = stderr_reader.interface.allocRemaining(self.allocator, .limited(max_output_size)) catch {
        return error.ReadFailure;
    };
    errdefer self.allocator.free(stderr);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                return error.ExitCodeFailure;
            }
            return stderr;
        },
        .signal, .stopped, .unknown => return error.ProcessTerminated,
    }
}

const VulkanValidationMode = enum {
    ignore,
    print,
    panic,
};

pub const EngineOptions = struct {
    vk_validation: VulkanValidationMode = .ignore,
    vk_metrics: bool = false,
    tracy: bool = false,

    // modules
    hrtsystem: bool = true,
    window: bool = true,
    gui: bool = true,
    shader_source_type: ShaderImport.SourceType = .embed,

    fn fromCli(b: *std.Build) EngineOptions {
        var options = EngineOptions {};

        if (b.option(bool, "vk-validation", "Enable vulkan validation")) |vk_validation| {
            options.vk_validation = if (vk_validation) .print else .ignore;
        }

        if (b.option(bool, "tracy", "Enable tracy integration")) |tracy| {
            options.tracy = tracy;
        }

        return options;
    }

    fn toBuildOptions(self: EngineOptions, b: *std.Build) *std.Build.Step.Options {
        const build_options = b.addOptions();
        build_options.addOption(VulkanValidationMode, "vk_validation", self.vk_validation);
        build_options.addOption(bool, "vk_metrics", self.vk_metrics);
        build_options.addOption(bool, "window", self.window);
        build_options.addOption(bool, "gui", self.gui);
        build_options.addOption(bool, "hrtsystem", self.hrtsystem);
        build_options.addOption(bool, "tracy", self.tracy);
        build_options.addOption(ShaderImport.SourceType, "shader_source_type", self.shader_source_type);

        return build_options;
    }
};

fn makeShadersModule(b: *std.Build, shader_source: *std.Build.Module, shader_imports: []const ShaderImport) *std.Build.Module {
    const stdout_shader_args = [_][]const u8{ "-Fo", "/dev/stdout" }; // TODO: windows

    var imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
    var contents = std.array_list.Managed(u8).init(b.allocator);

    contents.appendSlice(
        \\const ShaderSource = @import("shader_source");
        \\
        \\
    ) catch @panic("OOM");

    for (shader_imports) |shader_import| {
        imports.append(std.Build.Module.Import { .name = shader_import.name, .module = shader_import.shader.compile(b) }) catch @panic("OOM");
        const compile_cmd = switch (shader_import.shader.language) {
            .hlsl => std.mem.concat(b.allocator, []const u8, &[_][]const []const u8{ &Shader.Hlsl.compile_cmd, &[1][]const u8{ shader_import.shader.path }, &stdout_shader_args }) catch @panic("OOM"),
            .zig => &.{}, // TODO: zig hot reload, should probably just be done as part of the build system
        };
        const compile_cmd_str = b.fmt("\"{s}\"", .{ std.mem.join(b.allocator, "\", \"", compile_cmd) catch @panic("OOM") });
        contents.appendSlice(b.fmt(
            \\pub const {0s} = ShaderSource {{
            \\    .name = "{0s}",
            \\    .code = blk: {{
            \\        const bytes align(4) = @embedFile("{0s}").*;
            \\        break :blk @ptrCast(&bytes);
            \\    }},
            \\    .command = &[_][]const u8 {{ {1s} }},
            \\}};
            \\
            \\
        , .{ shader_import.name, compile_cmd_str })) catch @panic("OOM");
    }

    imports.append(std.Build.Module.Import { .name = "shader_source", .module = shader_source }) catch @panic("OOM");

    const write_files_step = b.addWriteFiles();
    const root = write_files_step.add("shaders.zig", contents.items);

    return b.createModule(.{
        .root_source_file = root,
        .imports = imports.items,
    });
}

fn makeHrtsystemShaders(b: *std.Build, shader_source: *std.Build.Module) *std.Build.Module {
    return makeShadersModule(b, shader_source, &[_]ShaderImport {
        ShaderImport { .shader = Shader { .language = .hlsl, .path = "src/lib/hrtsystem/shaders/render.hlsl" }, .name = "render", },
        ShaderImport { .shader = Shader { .language = .hlsl, .path = "src/lib/hrtsystem/shaders/background/equirectangular_to_equal_area.hlsl" }, .name = "equirectangular_to_equal_area", },
        ShaderImport { .shader = Shader { .language = .hlsl, .path = "src/lib/hrtsystem/shaders/background/fold.hlsl" }, .name = "background_fold", },
        ShaderImport { .shader = Shader { .language = .hlsl, .path = "src/lib/hrtsystem/shaders/local_light/triangle_power.hlsl" }, .name = "triangle_power", },
        ShaderImport { .shader = Shader { .language = .hlsl, .path = "src/lib/hrtsystem/shaders/local_light/geometry_power.hlsl" }, .name = "geometry_power", },
        ShaderImport { .shader = Shader { .language = .hlsl, .path = "src/lib/hrtsystem/shaders/local_light/instance_power.hlsl" }, .name = "instance_power", },
        ShaderImport { .shader = Shader { .language = .hlsl, .path = "src/lib/hrtsystem/shaders/local_light/fold3.hlsl" }, .name = "fold3", },
        ShaderImport { .shader = Shader { .language = .hlsl, .path = "src/lib/hrtsystem/shaders/local_light/fold1.hlsl" }, .name = "fold1", },
    });
}

fn makeEngineModule(b: *std.Build, options: EngineOptions,
    shader_source: *std.Build.Module,
    hrtsystem_shaders: *std.Build.Module,
    vulkan: *std.Build.Module,
    zgltf: *std.Build.Module,
    tinyexr: *std.Build.Module,
    wuffs: *std.Build.Module,
    glfw: *std.Build.Module,
    imgui: *std.Build.Module,
    tracy: *std.Build.Module,
) *std.Build.Module {
    var imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
    defer imports.deinit();

    imports.appendSlice(&[_]std.Build.Module.Import {
        .{ .name = "build_options", .module = options.toBuildOptions(b).createModule() },
        .{ .name = "vulkan", .module = vulkan },
        .{ .name = "shader_source", .module = shader_source },
    }) catch @panic("OOM");

    if (options.hrtsystem) {
        imports.appendSlice(&[_]std.Build.Module.Import {
            .{ .name = "wuffs", .module = wuffs },
            .{ .name = "tinyexr", .module = tinyexr },
            .{ .name = "zgltf", .module = zgltf },
            .{ .name = "hrtsystem_shaders", .module = hrtsystem_shaders },
        }) catch @panic("OOM");
    }

    if (options.window) {
        imports.append(std.Build.Module.Import { .name = "glfw", .module = glfw }) catch @panic("OOM");
        imports.append(std.Build.Module.Import { .name = "platform_shaders", .module = makeShadersModule(b, shader_source, &[_]ShaderImport {
            ShaderImport { .shader = Shader { .language = .zig, .path = "src/lib/gui/vertex.zig" }, .name = "vertex", },
            ShaderImport { .shader = Shader { .language = .zig, .path = "src/lib/gui/fragment.zig" }, .name = "fragment", },
        })}) catch @panic("OOM");
    }

    if (options.gui) {
        imports.append(std.Build.Module.Import { .name = "imgui", .module = imgui }) catch @panic("OOM");
    }

    if (options.tracy) {
        imports.append(std.Build.Module.Import { .name = "tracy", .module = tracy }) catch @panic("OOM");
    }

    const module = b.createModule(.{
        .root_source_file = b.path("src/lib/engine.zig"),
        .imports = imports.items,
        .link_libc = true, // always needed to load vulkan
    });

    return module;
}

fn makeZgltfModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    const zgltf = b.dependency("zgltf", .{}).module("zgltf");
    zgltf.optimize = .ReleaseFast;
    zgltf.resolved_target = target;
    return zgltf;
}

fn makeVulkanModule(b: *std.Build) *std.Build.Module {
    const vulkan_zig = b.dependency("vulkan_zig", .{});
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vk_generate_cmd = b.addRunArtifact(vulkan_zig.artifact("vulkan-zig-generator"));
    vk_generate_cmd.addFileArg(vulkan_headers.path("registry/vk.xml"));
    const vk_zig = vk_generate_cmd.addOutputFileArg("vk.zig");
    return b.addModule("vulkan-zig", .{
        .root_source_file = vk_zig,
        .optimize = .ReleaseFast,
    });
}

fn makeDCImguiModule(b: *std.Build, glfw: *std.Build.Module, target: std.Build.ResolvedTarget) *std.Build.Module {
    const dcimgui = b.dependency("dcimgui", .{});
    const imgui = b.dependency("imgui", .{});

    const step = b.addTranslateC(.{
        .root_source_file = dcimgui.path("dcimgui_nodefaultargfunctions.h"),
        .optimize = .ReleaseFast,
        .target = target,
    });
    step.addIncludePath(imgui.path(""));

    const module = step.createModule();
    module.link_libcpp = true;

    module.addCSourceFiles(.{
        .root = dcimgui.path(""),
        .files = &.{
            "dcimgui_nodefaultargfunctions.cpp",
        }
    });
    module.addIncludePath(dcimgui.path(""));
    module.addCSourceFiles(.{
        .root = imgui.path(""),
        .files = &.{
            "imgui.cpp",
            "imgui_draw.cpp",
            "imgui_demo.cpp",
            "imgui_widgets.cpp",
            "imgui_tables.cpp",
            "backends/imgui_impl_glfw.cpp",
        }, .flags = &.{
            "-DGLFW_INCLUDE_NONE",
            "-DIMGUI_IMPL_API=extern \"C\"",
        }
    });
    module.addIncludePath(imgui.path(""));
    for (glfw.include_dirs.items) |dir| {
        module.include_dirs.append(b.allocator, dir) catch @panic("OOM");
    }

    return module;
}

fn makeTinyExrModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    const tinyexr = b.dependency("tinyexr", .{});
    const miniz_path = "deps/miniz/";

    const step = b.addTranslateC(.{
        .root_source_file = tinyexr.path("tinyexr.h"),
        .optimize = .ReleaseFast,
        .target = target,
    });

    const module = step.createModule();
    module.link_libcpp = true;
    module.sanitize_c = .off; // fails :( https://github.com/syoyo/tinyexr/issues/187
    module.addCSourceFiles(.{
        .root = tinyexr.path(""),
        .files = &.{
            "tinyexr.cc",
            miniz_path ++ "miniz.c",
        },
    });
    module.addIncludePath(tinyexr.path(""));
    module.addIncludePath(tinyexr.path(miniz_path));

    return module;
}

fn makeWuffsModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    const base = b.dependency("wuffs", .{});

    const step = b.addTranslateC(.{
        .root_source_file = base.path("release/c/wuffs-v0.4.c"),
        .optimize = .ReleaseFast,
        .target = target,
    });

    const module = step.createModule();
    module.addCSourceFile(.{
        .file = base.path("release/c/wuffs-v0.4.c"),
        .flags = &.{
            "-DWUFFS_IMPLEMENTATION",
        },
    });
    module.addIncludePath(base.path("release/c/"));

    return module;
}

fn makeTracyModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    const base = b.dependency("tracy", .{});

    const step = b.addTranslateC(.{
        .root_source_file = base.path("public/tracy/TracyC.h"),
        .optimize = .ReleaseFast,
        .target = target,
    });
    step.defineCMacro("TRACY_ENABLE", null);

    const module = step.createModule();
    module.addCSourceFile(.{
        .file = base.path("public/TracyClient.cpp"),
        .flags = &.{
            "-DTRACY_ENABLE",
        },
    });
    module.link_libc = true;
    module.link_libcpp = true;
    module.sanitize_c = .off; // fails :(

    return module;
}

fn makeGlfwModule(b: *std.Build, target: std.Build.ResolvedTarget) !*std.Build.Module {
    const glfw = b.dependency("glfw", .{});

    const step = b.addTranslateC(.{
        .root_source_file = glfw.path("include/GLFW/glfw3.h"),
        .optimize = .ReleaseFast,
        .target = target,
    });
    step.defineCMacro("GLFW_INCLUDE_NONE", null);

    const module = step.createModule();

    if (target.result.os.tag == .linux) {
        const wayland_include_path = generateWaylandHeaders(b, glfw.path(""));
        module.addIncludePath(wayland_include_path);
    }

    // collect source files
    const sources = blk: {
        var sources = std.array_list.Managed([]const u8).init(b.allocator);

        const source_path = "src/";

        const general_sources = [_][]const u8 {
            source_path ++ "context.c",
            source_path ++ "init.c",
            source_path ++ "input.c",
            source_path ++ "monitor.c",
            source_path ++ "vulkan.c",
            source_path ++ "window.c",
            source_path ++ "egl_context.c",
            source_path ++ "osmesa_context.c",
            source_path ++ "platform.c",
            source_path ++ "null_init.c",
            source_path ++ "null_window.c",
            source_path ++ "null_joystick.c",
            source_path ++ "null_monitor.c",
        };

        const linux_sources = [_][]const u8 {
            source_path ++ "posix_time.c",
            source_path ++ "posix_thread.c",
            source_path ++ "posix_module.c",
            source_path ++ "posix_poll.c",
            source_path ++ "linux_joystick.c",
        };

        const wayland_sources = [_][]const u8 {
            source_path ++ "wl_init.c",
            source_path ++ "wl_monitor.c",
            source_path ++ "wl_window.c",
        };

        const windows_sources = [_][]const u8 {
            source_path ++ "win32_thread.c",
            source_path ++ "wgl_context.c",
            source_path ++ "win32_init.c",
            source_path ++ "win32_monitor.c",
            source_path ++ "win32_time.c",
            source_path ++ "win32_joystick.c",
            source_path ++ "win32_window.c",
            source_path ++ "win32_module.c",
        };

        try sources.appendSlice(&general_sources);

        if (target.result.os.tag == .linux) {
            try sources.appendSlice(&linux_sources);
            try sources.appendSlice(&wayland_sources);
        } else if (target.result.os.tag == .windows) try sources.appendSlice(&windows_sources);

        break :blk sources.items;
    };

    const flags = blk: {
        var flags = std.array_list.Managed([]const u8).init(b.allocator);

        if (target.result.os.tag == .linux) {
            try flags.append("-D_GLFW_WAYLAND");
        } else if (target.result.os.tag == .windows) try flags.append("-D_GLFW_WIN32");

        break :blk flags.items;
    };

    module.addCSourceFiles(.{
        .root = glfw.path(""),
        .files = sources,
        .flags = flags,
    });
    module.addIncludePath(glfw.path("include"));

    if (target.result.os.tag == .linux) {
        module.linkSystemLibrary("wayland-client", .{});
    } else if (target.result.os.tag == .windows) module.linkSystemLibrary("gdi32", .{});

    return module;
}

fn generateWaylandHeaders(b: *std.Build, path: std.Build.LazyPath) std.Build.LazyPath {
    const protocols_dir = path.path(b, "deps/wayland");

    const write_file_step = b.addWriteFiles();
    write_file_step.step.name = "Write Wayland headers";

    generateWaylandHeader(b, write_file_step, protocols_dir, "xdg-shell");
    generateWaylandHeader(b, write_file_step, protocols_dir, "xdg-decoration-unstable-v1");
    generateWaylandHeader(b, write_file_step, protocols_dir, "xdg-activation-v1");
    generateWaylandHeader(b, write_file_step, protocols_dir, "viewporter");
    generateWaylandHeader(b, write_file_step, protocols_dir, "relative-pointer-unstable-v1");
    generateWaylandHeader(b, write_file_step, protocols_dir, "pointer-constraints-unstable-v1");
    generateWaylandHeader(b, write_file_step, protocols_dir, "idle-inhibit-unstable-v1");
    generateWaylandHeader(b, write_file_step, protocols_dir, "fractional-scale-v1");
    generateWaylandHeader(b, write_file_step, protocols_dir, "wayland");

    return write_file_step.getDirectory();
}

fn generateWaylandHeader(b: *std.Build, write_file_step: *std.Build.Step.WriteFile, protocols_dir: std.Build.LazyPath, protocol_name: []const u8) void {
    const in_xml = protocols_dir.path(b, b.fmt("{s}.xml", .{ protocol_name }));

    const out_source_name = b.fmt("{s}-client-protocol-code.h", .{ protocol_name });
    const gen_private_code_step = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    gen_private_code_step.addFileArg(in_xml);
    const out_source = gen_private_code_step.addOutputFileArg(out_source_name);
    _ = write_file_step.addCopyFile(out_source, out_source_name);

    const out_header_name = b.fmt("{s}-client-protocol.h", .{ protocol_name });
    const gen_client_header_step = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    gen_client_header_step.addFileArg(in_xml);
    const out_header = gen_client_header_step.addOutputFileArg(out_header_name);
    _ = write_file_step.addCopyFile(out_header, out_header_name);
}

const ShaderImport = struct {
    const SourceType = enum {
        embed, // embed SPIRV shaders into binary at compile time
        load,  // dynamically load shader and compile to SPIRV at runtime (but also check build-time correctness)
    };

    shader: Shader,
    name: []const u8,
};

const Shader = struct {
    const Hlsl = struct {
        const compile_cmd = [_][]const u8 {
            "dxc",
            "-HV", "2021",
            "-spirv",
            "-fspv-target-env=vulkan1.3",
            "-fvk-use-scalar-layout",
            "-Ges", // strict mode
            "-WX", // treat warnings as errors
            "-T",
            "cs_6_7", // assume compute
        };
    };

    const SourceLanguage = enum {
        zig,
        hlsl,
    };

    language: SourceLanguage,
    path: []const u8,

    fn compile(self: Shader, b: *std.Build) *std.Build.Module {
        const input_file_path = b.path(self.path);

        const spv_file_path = switch (self.language) {
            .zig => blk: {
                const target = b.resolveTargetQuery(.{
                    .cpu_arch = .spirv64,
                    .os_tag = .vulkan,
                    .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
                    .ofmt = .spirv,
                });

                const zig_extension = ".zig";
                const object = b.addObject(.{
                    .name = std.fs.path.basename(self.path[0..self.path.len - zig_extension.len]),
                    .root_module = b.createModule(.{
                        .root_source_file = input_file_path,
                        .target = target,
                    }),
                });

                const spv_file = object.getEmittedBin();

                // spirv-opt pass to remove illegal dead code that zig sometimes emits
                const compile_shader = std.Build.Step.Run.create(b, b.fmt("spirv-opt {s}", .{ self.path }));
                compile_shader.addArg("spirv-opt");
                compile_shader.addArg("--relax-logical-pointer"); // currently fails
                compile_shader.addArg("--trim-capabilities"); // zig adds unused ones
                compile_shader.addArg("-O");
                compile_shader.addFileArg(spv_file);
                compile_shader.addArg("-o");
                const spv_file_opt = compile_shader.addOutputFileArg(b.fmt("{s}.spv", .{ self.path }));

                break :blk spv_file_opt;
            },
            .hlsl => blk: {
                const get_dependendies = std.Build.Step.Run.create(b, b.fmt("get dependencies of {s}", .{ self.path }));
                get_dependendies.addArgs(&Hlsl.compile_cmd);
                get_dependendies.addFileArg(input_file_path);
                get_dependendies.addArg("-MF");
                _ = get_dependendies.addDepFileOutputArg(b.fmt("{s}.d", .{ self.path }));

                const compile_shader = std.Build.Step.Run.create(b, b.fmt("compile {s}", .{ self.path }));
                compile_shader.addArgs(&Hlsl.compile_cmd);
                compile_shader.addFileArg(input_file_path);
                compile_shader.addArg("-Zi"); // include debug info
                compile_shader.addArg("-Fo"); // output file after this
                const spv_file = compile_shader.addOutputFileArg(b.fmt("{s}.spv", .{ self.path }));

                compile_shader.step.dependOn(&get_dependendies.step);
                compile_shader.dep_output_file = get_dependendies.argv.getLast().output_file;

                break :blk spv_file;
            },
        };

        return b.createModule(.{
            .root_source_file = spv_file_path,
        });
    }
};
