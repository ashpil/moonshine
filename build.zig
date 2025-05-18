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
    const glfw = try makeGlfwModule(b, vulkan, target);
    const imgui = makeDCImguiModule(b, glfw);
    const tinyexr = makeTinyExrModule(b);
    const wuffs = makeWuffsModule(b);
    const zgltf = makeZgltfModule(b);
    const shader_source = b.createModule(.{
        .root_source_file = b.path("src/lib/core/shader_source.zig"),
    });
    const hrtsystem_shaders = makeHrtsystemShaders(b, shader_source);
    const default_engine_options = EngineOptions.fromCli(b);

    var compiles = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);

    // TODO: make custom test runner parallel + share some state across tests
    try compiles.append(blk: {
        var engine_options = default_engine_options;
        engine_options.vk_validation = .panic;
        engine_options.window = false;
        engine_options.gui = false;
        engine_options.shader_source_type = .embed;
        const engine = makeEngineModule(b, engine_options, shader_source, hrtsystem_shaders, vulkan, zgltf, tinyexr, wuffs, glfw, imgui);

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
        const tests = b.addTest(.{
            .name = "vector-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib/vector.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        break :blk tests;
    });

    // online exe
    try compiles.append(blk: {
        var engine_options = default_engine_options;
        engine_options.vk_metrics = true;
        engine_options.shader_source_type = if (target.result.os.tag == .linux) .load else .embed; // hot reload only works on linux atm
        const engine = makeEngineModule(b, engine_options, shader_source, hrtsystem_shaders, vulkan, zgltf, tinyexr, wuffs, glfw, imgui);
        const exe = b.addExecutable(.{
            .name = "online",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bin/online/online.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &[_]std.Build.Module.Import {
                    .{ .name = "vulkan", .module = vulkan },
                    .{ .name = "engine", .module = engine },
                    .{ .name = "shaders", .module = makeShadersModule(b, shader_source, &[_]ShaderImport {
                        ShaderImport { .shader = Shader { .type = .compute, .path = "src/bin/online/input.hlsl", }, .name = "input" },
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
        const engine = makeEngineModule(b, engine_options, shader_source, hrtsystem_shaders, vulkan, zgltf, tinyexr, wuffs, glfw, imgui);
        const exe = b.addExecutable(.{
            .name = "offline",
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
        const engine = makeEngineModule(b, engine_options, shader_source, hrtsystem_shaders, vulkan, zgltf, tinyexr, wuffs, glfw, imgui);

        // once https://github.com/ziglang/zig/issues/9698 lands
        // wont need to make own header
        const zig_lib = b.addSharedLibrary(.{
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

        const lib = b.addSharedLibrary(.{
            .name = "hdMoonshine",
            .target = target,
            .optimize = optimize,
        });
        lib.addCSourceFiles(.{
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
        lib.linkLibrary(zig_lib);

        // options
        const usd_dir = b.option([]const u8, "usd-path", "Where your USD SDK is installed.") orelse "../USD";
        const tbb_dir = b.option([]const u8, "tbb-path", "Where your TBB is installed.");
        const usd_monolithic = b.option(bool, "usd-monolithic", "Whether USD was built monolithically.") orelse false;

        // link against usd produced libraries
        lib.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ usd_dir, "lib/" }) });
        if (usd_monolithic) {
            lib.linkSystemLibrary("usd_ms");
        } else {
            lib.linkSystemLibrary("usd_hd");
            lib.linkSystemLibrary("usd_sdr");
            lib.linkSystemLibrary("usd_hio");
        }

        // include headers necessary for usd
        lib.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ usd_dir, "include/" }) });
        if (tbb_dir) |dir| lib.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dir, "include/" }) });

        // might need python headers if USD built with python support
        {
            var out_code: u8 = undefined;
            var iter = std.mem.splitScalar(u8, b.runAllowFail(&.{ "python3-config", "--includes" }, &out_code, .Inherit) catch b.runAllowFail(&.{ "python-config", "--includes" }, &out_code, .Inherit) catch "", ' ');
            while (iter.next()) |include_dir| lib.addSystemIncludePath(.{ .cwd_relative = include_dir[2..] });
        }

        // deal with the fact that USD is not (supposed to be) compiled with clang
        // make nicer once https://github.com/ziglang/zig/issues/3936
        {
            // link against stdlibc++
            lib.addObjectFile(.{ .cwd_relative = std.mem.trim(u8, b.run(&.{ "g++", "-print-file-name=libstdc++.so" }), &std.ascii.whitespace) });

            // need stdlibc++ include directories
            // i've had to do some arcane magic to figure out what to do here,
            // and i'm not even convinced it'll work on any system other than mine
            var first = true;
            var iter = std.mem.splitScalar(u8, runAllowFailStderr(b, &.{ "g++", "-E", "-Wp,-v", "-xc++", "/dev/null" }) catch "", '\n');
            while (iter.next()) |include_dir| if (include_dir.len > 0 and include_dir[0] == ' ') {
                if (first) {
                    lib.addIncludePath(.{ .cwd_relative = include_dir[1..] });
                } else {
                    lib.addSystemIncludePath(.{ .cwd_relative = include_dir[1..] });
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

pub fn runAllowFailStderr(self: *std.Build, argv: []const []const u8) ![]u8 {
    const max_output_size = 400 * 1024;
    var child = std.process.Child.init(argv, self.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.env_map = &self.graph.env_map;

    try child.spawn();

    const stderr = child.stderr.?.reader().readAllAlloc(self.allocator, max_output_size) catch {
        return error.ReadFailure;
    };
    errdefer self.allocator.free(stderr);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.ExitCodeFailure;
            return stderr;
        },
        .Signal, .Stopped, .Unknown => {
            return error.ProcessTerminated;
        },
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

        return options;
    }

    fn toBuildOptions(self: EngineOptions, b: *std.Build) *std.Build.Step.Options {
        const build_options = b.addOptions();
        build_options.addOption(VulkanValidationMode, "vk_validation", self.vk_validation);
        build_options.addOption(bool, "vk_metrics", self.vk_metrics);
        build_options.addOption(bool, "window", self.window);
        build_options.addOption(bool, "gui", self.gui);
        build_options.addOption(bool, "hrtsystem", self.hrtsystem);
        build_options.addOption(ShaderImport.SourceType, "shader_source_type", self.shader_source_type);

        return build_options;
    }
};

fn makeShadersModule(b: *std.Build, shader_source: *std.Build.Module, shader_imports: []const ShaderImport) *std.Build.Module {
    const stdout_shader_args = [_][]const u8{ "-Fo", "/dev/stdout" }; // TODO: windows

    var imports = std.ArrayList(std.Build.Module.Import).init(b.allocator);
    var contents = std.ArrayList(u8).init(b.allocator);

    contents.appendSlice(
        \\const ShaderSource = @import("shader_source");
        \\
        \\
    ) catch @panic("OOM");

    for (shader_imports) |shader_import| {
        imports.append(std.Build.Module.Import { .name = shader_import.name, .module = shader_import.shader.compile(b) }) catch @panic("OOM");
        contents.appendSlice(b.fmt(
            \\pub const {0s} = ShaderSource {{
            \\    .name = "{0s}",
            \\    .code = blk: {{
            \\        const bytes align(4) = @embedFile("{0s}").*;
            \\        break :blk @ptrCast(&bytes);
            \\    }},
            \\    .command = &[_][]const u8 {{ "{1s}" }},
            \\}};
            \\
            \\
        , .{ shader_import.name, std.mem.join(b.allocator, "\", \"", std.mem.concat(b.allocator, []const u8, &[_][]const []const u8{ &shader_import.shader.compileCommand(), &[1][]const u8{ shader_import.shader.path }, &stdout_shader_args }) catch @panic("OOM")) catch @panic("OOM") })) catch @panic("OOM");
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
        ShaderImport { .shader = Shader { .type = .compute, .path = "src/lib/hrtsystem/shaders/main.hlsl" }, .name = "main", },
        ShaderImport { .shader = Shader { .type = .compute, .path = "src/lib/hrtsystem/shaders/background/equirectangular_to_equal_area.hlsl" }, .name = "equirectangular_to_equal_area", },
        ShaderImport { .shader = Shader { .type = .compute, .path = "src/lib/hrtsystem/shaders/background/fold.hlsl" }, .name = "background_fold", },
        ShaderImport { .shader = Shader { .type = .compute, .path = "src/lib/hrtsystem/shaders/local_light/triangle_power.hlsl" }, .name = "triangle_power", },
        ShaderImport { .shader = Shader { .type = .compute, .path = "src/lib/hrtsystem/shaders/local_light/geometry_power.hlsl" }, .name = "geometry_power", },
        ShaderImport { .shader = Shader { .type = .compute, .path = "src/lib/hrtsystem/shaders/local_light/instance_power.hlsl" }, .name = "instance_power", },
        ShaderImport { .shader = Shader { .type = .compute, .path = "src/lib/hrtsystem/shaders/local_light/fold3.hlsl" }, .name = "fold3", },
        ShaderImport { .shader = Shader { .type = .compute, .path = "src/lib/hrtsystem/shaders/local_light/fold1.hlsl" }, .name = "fold1", },
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
) *std.Build.Module {
    var imports = std.ArrayList(std.Build.Module.Import).init(b.allocator);
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
    }

    if (options.gui) {
        imports.append(std.Build.Module.Import { .name = "imgui", .module = imgui }) catch @panic("OOM");
    }

    const module = b.createModule(.{
        .root_source_file = b.path("src/lib/engine.zig"),
        .imports = imports.items,
        .link_libc = true, // always needed to load vulkan
    });

    return module;
}

fn makeZgltfModule(b: *std.Build) *std.Build.Module {
    const zgltf = b.dependency("zgltf", .{}).module("zgltf");
    zgltf.optimize = .ReleaseFast;
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

fn makeDCImguiModule(b: *std.Build, glfw: *std.Build.Module) *std.Build.Module {
    const dcimgui = b.dependency("dcimgui", .{});
    const imgui = b.dependency("imgui", .{});

    const write_files_step = b.addWriteFiles();
    const root = write_files_step.add("imgui.zig",
        \\pub usingnamespace @cImport({
        \\    @cInclude("dcimgui.h");
        \\});
        \\
        \\const glfw = @import("glfw");
        \\
        \\pub extern fn ImGui_ImplGlfw_InitForVulkan(*glfw.GLFWwindow, bool) bool;
        \\pub extern fn ImGui_ImplGlfw_Shutdown() void;
        \\pub extern fn ImGui_ImplGlfw_NewFrame() void;
    );

    const module = b.createModule(.{
        .root_source_file = root,
        .link_libcpp = true,
        .optimize = .ReleaseFast,
        .imports = &[_]std.Build.Module.Import {
            .{ .name = "glfw", .module = glfw },
        }
    });

    module.addCSourceFiles(.{
        .root = dcimgui.path(""),
        .files = &.{
            "dcimgui.cpp",
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

fn makeTinyExrModule(b: *std.Build) *std.Build.Module {
    const tinyexr = b.dependency("tinyexr", .{});
    const miniz_path = "deps/miniz/";

    const write_files_step = b.addWriteFiles();
    const root = write_files_step.add("tinyexr.zig",
        \\pub usingnamespace @cImport(@cInclude("tinyexr.h"));
    );

    const module = b.createModule(.{
        .root_source_file = root,
        .link_libcpp = true,
        .optimize = .ReleaseFast,
        .sanitize_c = false, // fails :( https://github.com/syoyo/tinyexr/issues/187
    });

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

fn makeWuffsModule(b: *std.Build) *std.Build.Module {
    const base = b.dependency("wuffs", .{});

    const write_files_step = b.addWriteFiles();
    const root = write_files_step.add("wuffs.zig",
        \\pub usingnamespace @cImport(@cInclude("wuffs-v0.4.c"));
    );

    const module = b.createModule(.{
        .root_source_file = root,
        .link_libc = true,
        .optimize = .ReleaseFast,
    });

    module.addCSourceFile(.{
        .file = base.path("release/c/wuffs-v0.4.c"),
        .flags = &.{
            "-DWUFFS_IMPLEMENTATION",
        },
    });

    module.addIncludePath(base.path("release/c/"));

    return module;
}

fn makeGlfwModule(b: *std.Build, vulkan: *std.Build.Module, target: std.Build.ResolvedTarget) !*std.Build.Module {
    const glfw = b.dependency("glfw", .{});

    const write_files_step = b.addWriteFiles();
    const root = write_files_step.add("imgui.zig",
        \\pub usingnamespace @cImport({
        \\    @cDefine("GLFW_INCLUDE_NONE", {});
        \\    @cInclude("GLFW/glfw3.h");
        \\});
        \\
        \\const vk = @import("vulkan");
        \\const c = @This();
        \\
        \\pub extern fn glfwGetInstanceProcAddress(vk.Instance, [*:0]const u8) vk.PfnVoidFunction;
        \\pub extern fn glfwCreateWindowSurface(vk.Instance, *c.GLFWwindow, ?*const vk.AllocationCallbacks, *vk.SurfaceKHR) vk.Result;
        \\pub extern fn glfwGetPhysicalDevicePresentationSupport(vk.Instance, vk.PhysicalDevice, u32) c_int;
        \\pub extern fn glfwInitVulkanLoader(vk.PfnGetInstanceProcAddr) void;
    );

    const module = b.createModule(.{
        .root_source_file = root,
        .link_libc = true,
        .optimize = .ReleaseFast,
        .target = target,
        .imports = &[_]std.Build.Module.Import {
            .{ .name = "vulkan", .module = vulkan },
        }
    });

    const build_wayland = b.option(bool, "wayland", "Support Wayland on Linux. (default: true)") orelse true;
    const build_x11 = b.option(bool, "x11", "Support X11 on Linux. (default: true)") orelse true;

    if (!build_wayland and !build_x11) return error.NoSelectedLinuxDisplayServerProtocol;

    if (target.result.os.tag == .linux and build_wayland) {
        const wayland_include_path = generateWaylandHeaders(b, glfw.path(""));
        module.addIncludePath(wayland_include_path);
    }

    // collect source files
    const sources = blk: {
        var sources = std.ArrayList([]const u8).init(b.allocator);

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
            source_path ++ "xkb_unicode.c",
            source_path ++ "linux_joystick.c",
        };

        const x11_sources = [_][]const u8 {
            source_path ++ "x11_init.c",
            source_path ++ "x11_monitor.c",
            source_path ++ "x11_window.c",
            source_path ++ "glx_context.c",
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
            if (build_wayland) try sources.appendSlice(&wayland_sources);
            if (build_x11) try sources.appendSlice(&x11_sources);
        } else if (target.result.os.tag == .windows) try sources.appendSlice(&windows_sources);

        break :blk sources.items;
    };

    const flags = blk: {
        var flags = std.ArrayList([]const u8).init(b.allocator);

        if (target.result.os.tag == .linux) {
            if (build_wayland) try flags.append("-D_GLFW_WAYLAND");
            if (build_x11) try flags.append("-D_GLFW_X11");
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
        if (build_wayland) module.linkSystemLibrary("wayland-client", .{});
        if (build_x11) module.linkSystemLibrary("X11", .{});
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
    const ShaderType = enum {
        compute,
        ray_tracing,

        fn dxcProfile(self: ShaderType) []const u8 {
            return switch (self) {
                .compute => "cs_6_7",
                .ray_tracing => "lib_6_7",
            };
        }
    };

    path: []const u8,
    type: ShaderType,

    const include_shader_debug_info = false;
    const shader_compile_cmd = [_][]const u8 {
        "dxc",
        "-HV", "2021",
        "-spirv",
        "-fspv-target-env=vulkan1.3",
        "-fvk-use-scalar-layout",
        "-Ges", // strict mode
        "-WX", // treat warnings as errors
    } ++ (if (include_shader_debug_info) [_][]const u8{ "-Zi" } else [_][]const u8{});

    fn compileCommand(self: Shader) [shader_compile_cmd.len + 2][]const u8 {
        return shader_compile_cmd ++ [_][]const u8{ "-T", self.type.dxcProfile() };
    }

    fn compile(self: Shader, b: *std.Build) *std.Build.Module {
        const input_file_path = b.path(self.path);

        const get_dependendies = std.Build.Step.Run.create(b, b.fmt("get dependencies of {s}", .{ self.path }));
        get_dependendies.addArgs(&self.compileCommand());
        get_dependendies.addFileArg(input_file_path);
        get_dependendies.addArg("-MF");
        _ = get_dependendies.addDepFileOutputArg(b.fmt("{s}.d", .{ self.path }));

        const compile_shader = std.Build.Step.Run.create(b, b.fmt("compile {s}", .{ self.path }));
        compile_shader.addArgs(&self.compileCommand());
        compile_shader.addFileArg(input_file_path);
        compile_shader.addArg("-Fo");
        const spv_file = compile_shader.addOutputFileArg(b.fmt("{s}.spv", .{ self.path }));

        compile_shader.step.dependOn(&get_dependendies.step);
        compile_shader.dep_output_file = get_dependendies.argv.getLast().output_file;

        return b.createModule(.{
            .root_source_file = spv_file,
        });
    }
};
