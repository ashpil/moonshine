const std = @import("std");
const vkgen = @import("./deps/vulkan-zig/generator/index.zig");

pub fn build(b: *std.build.Builder) void {

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    // packages/libraries we'll need below
    const vk = blk: {
        const vk_xml_path = b.build_root.join(b.allocator, &[_][]const u8{
            "deps/vk.xml",
        }) catch unreachable;
        break :blk vkgen.VkGenerateStep.create(b, vk_xml_path).getModule();
    };
    const glfw = makeGlfwLibrary(b, target) catch unreachable;
    const cimgui = makeCImguiLibrary(b, target, glfw);
    const tinyexr = makeTinyExrLibrary(b, target);
    const default_engine_options = EngineOptions.fromCli(b);

    var exes = std.ArrayList(*std.Build.CompileStep).init(b.allocator);

    // TODO: make custom test runner parallel + share some state across tests
    exes.append(blk: {
        var engine_options = default_engine_options;
        engine_options.window = false;
        engine_options.gui = false;
        const engine = makeEngineModule(b, vk, engine_options) catch unreachable;

        const tests = b.addTest(.{
            .name = "tests",
            .root_source_file = .{ .path = "engine/tests.zig" },
            .test_runner = "engine/test_runner.zig",
            .target = target,
            .optimize = optimize,
        });
        tests.addModule("vulkan", vk);
        tests.addModule("engine", engine);
        tinyexr.add(tests);

        break :blk tests;
    }) catch unreachable;

    // online exe
    exes.append(blk: {
        var engine_options = default_engine_options;
        engine_options.vk_metrics = true;
        engine_options.shader_source = .load; // for hot shader reload
        const engine = makeEngineModule(b, vk, engine_options) catch unreachable;
        const exe = b.addExecutable(.{
            .name = "online",
            .root_source_file = .{ .path = "online/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.addModule("vulkan", vk);
        exe.addModule("engine", engine);
        glfw.add(exe);
        tinyexr.add(exe);
        cimgui.add(exe);

        break :blk exe;
    }) catch unreachable;

    // offline exe
    exes.append(blk: {
        var engine_options = default_engine_options;
        engine_options.window = false;
        engine_options.gui = false;
        const engine = makeEngineModule(b, vk, engine_options) catch unreachable;
        const exe = b.addExecutable(.{
            .name = "offline",
            .root_source_file = .{ .path = "offline/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.addModule("vulkan", vk);
        exe.addModule("engine", engine);
        tinyexr.add(exe);

        break :blk exe;
    }) catch unreachable;
    
    // create run step for all exes
    for (exes.items) |exe| {
        const install = b.addInstallArtifact(exe, .{});
        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        if (b.args) |args| {
            run.addArgs(args);
        }

        b.step(std.fmt.allocPrint(b.allocator, "run-{s}", .{ exe.name }) catch unreachable, std.fmt.allocPrint(b.allocator, "Run {s}", .{ exe.name }) catch unreachable).dependOn(&run.step);
    }

    // create check step that type-checks all exes
    // probably does a bit more atm but what can you do
    const check_step = b.step("check", "check all");
    for (exes.items) |exe| {
        check_step.dependOn(&exe.step);
    }
}

const base_shader_compile_cmd = [_][]const u8 {
    "dxc",
    "-HV", "2021",
    "-spirv",
    "-fspv-target-env=vulkan1.3",
    "-fvk-use-scalar-layout",
    "-Ges", // strict mode
    "-WX", // treat warnings as errors
};

const rt_shader_compile_cmd = base_shader_compile_cmd ++ [_][]const u8 { "-T", "lib_6_7" };
const compute_shader_compile_cmd = base_shader_compile_cmd ++ [_][]const u8 { "-T", "cs_6_7" };

const ShaderSource = enum {
    embed, // embed SPIRV shaders into binary at compile time
    load,  // dynamically load shader and compile to SPIRV at runtime
};

pub const EngineOptions = struct {
    vk_validation: bool = false,
    vk_metrics: bool = false,
    shader_source: ShaderSource = .embed,
    rt_shader_compile_cmd: []const []const u8 = &(rt_shader_compile_cmd ++ [_][]const u8{ "-Fo", "/dev/stdout" }), // TODO: windows
    compute_shader_compile_cmd: []const []const u8 = &(compute_shader_compile_cmd ++ [_][]const u8{ "-Fo", "/dev/stdout" }), // TODO: windows

    // modules
    hrtsystem: bool = true,
    window: bool = true,
    gui: bool = true,

    fn fromCli(b: *std.build.Builder) EngineOptions {
        var options = EngineOptions {};

        if (b.option(bool, "vk-validation", "Enable vulkan validation")) |vk_validation| {
            options.vk_validation = vk_validation;
        }

        return options;
    }
};

fn makeEngineModule(b: *std.build.Builder, vk: *std.build.Module, options: EngineOptions) !*std.build.Module {
    const zgltf = b.createModule(.{
        .source_file = .{ .path = "deps/zgltf/src/main.zig" },
    });
    const zigimg = b.createModule(.{
        .source_file = .{ .path = "deps/zigimg/zigimg.zig" },
    });

    // shaders
    const rt_shader_comp = vkgen.ShaderCompileStep.create(b, &rt_shader_compile_cmd, "-Fo");
    rt_shader_comp.add("@\"hrtsystem/input.hlsl\"", "shaders/hrtsystem/input.hlsl", .{});
    rt_shader_comp.add("@\"hrtsystem/main.hlsl\"", "shaders/hrtsystem/main.hlsl", .{
        .watched_files = &.{
            "shaders/hrtsystem/bindings.hlsl",
            "shaders/hrtsystem/camera.hlsl",
            "shaders/hrtsystem/geometry.hlsl",
            "shaders/hrtsystem/integrator.hlsl",
            "shaders/hrtsystem/intersection.hlsl",
            "shaders/hrtsystem/light.hlsl",
            "shaders/hrtsystem/material.hlsl",
            "shaders/hrtsystem/reflection_frame.hlsl",
            "shaders/utils/random.hlsl",
            "shaders/utils/math.hlsl",
        }
    });

    const compute_shader_comp = vkgen.ShaderCompileStep.create(b, &compute_shader_compile_cmd, "-Fo");

    // actual engine
    const build_options = b.addOptions();
    build_options.addOption(bool, "vk_validation", options.vk_validation);
    build_options.addOption(bool, "vk_metrics", options.vk_metrics);
    build_options.addOption(ShaderSource, "shader_source", options.shader_source);
    build_options.addOption([]const []const u8, "rt_shader_compile_cmd", options.rt_shader_compile_cmd);  // shader compilation command to use if shaders are to be loaded at runtime
    build_options.addOption([]const []const u8, "compute_shader_compile_cmd", options.compute_shader_compile_cmd);  // shader compilation command to use if shaders are to be loaded at runtime
    build_options.addOption(bool, "window", options.window);
    build_options.addOption(bool, "gui", options.gui);
    build_options.addOption(bool, "hrtsystem", options.hrtsystem);

    return b.createModule(.{
        .source_file = .{ .path = "engine/engine.zig" },
        .dependencies = &[_]std.Build.ModuleDependency {
            .{
                .name = "vulkan",
                .module = vk,
            },
            .{
                .name = "zgltf",
                .module = zgltf,
            },
            .{
                .name = "zigimg",
                .module = zigimg,
            },
            .{
                .name = "build_options",
                .module = build_options.createModule(),
            },
            .{
                .name = "rt_shaders",
                .module = rt_shader_comp.getModule(),
            },
            .{
                .name = "compute_shaders",
                .module = compute_shader_comp.getModule(),
            },
        },
    });
}

const CLibrary = struct {
    include_path: []const u8,
    library: *std.build.LibExeObjStep,

    fn add(self: CLibrary, exe: *std.Build.CompileStep) void {
        exe.linkLibrary(self.library);
        exe.addIncludePath(.{ .path = self.include_path });
    }
};

fn makeCImguiLibrary(b: *std.build.Builder, target: std.zig.CrossTarget, glfw: CLibrary) CLibrary {
    const path = "./deps/cimgui/";

    const lib = b.addStaticLibrary(.{
        .name = "cimgui",
        .target = target,
        .optimize = .ReleaseFast,
    });
    lib.linkLibCpp();
    lib.addCSourceFiles(&.{
        path ++ "cimgui.cpp",
        path ++ "imgui/imgui.cpp",
        path ++ "imgui/imgui_draw.cpp",
        path ++ "imgui/imgui_demo.cpp",
        path ++ "imgui/imgui_widgets.cpp",
        path ++ "imgui/imgui_tables.cpp",
        path ++ "imgui/backends/imgui_impl_glfw.cpp",
    }, &.{
        "-DGLFW_INCLUDE_NONE",
        "-DIMGUI_IMPL_API=extern \"C\"",
    });
    lib.addIncludePath(.{ .path = path ++ "imgui/" });
    lib.addIncludePath(.{ .path = glfw.include_path });

    return CLibrary {
        .include_path = path,
        .library = lib,
    };
}

fn makeTinyExrLibrary(b: *std.build.Builder, target: std.zig.CrossTarget) CLibrary {
    const tinyexr_path = "./deps/tinyexr/";
    const miniz_path = tinyexr_path ++ "deps/miniz/";

    const lib = b.addStaticLibrary(.{
        .name = "tinyexr",
        .target = target,
        .optimize = .ReleaseFast,
    });
    lib.linkLibCpp();
    lib.addIncludePath(.{ .path = miniz_path });
    lib.addCSourceFiles(&.{
        tinyexr_path ++ "tinyexr.cc",
        miniz_path ++ "miniz.c",
    }, &.{});

    return CLibrary {
        .include_path = tinyexr_path,
        .library = lib,
    };
}

// adapted from mach glfw
fn makeGlfwLibrary(b: *std.build.Builder, target: std.zig.CrossTarget) !CLibrary {
    const path = "./deps/glfw/";
    const lib = b.addStaticLibrary(.{
        .name = "glfw",
        .target = target,
        .optimize = .ReleaseFast,
    });

    const build_wayland = b.option(bool, "wayland", "Support Wayland on Linux. (default: true)") orelse true;
    const build_x11 = b.option(bool, "x11", "Support X11 on Linux. (default: true)") orelse true;

    if (!build_wayland and !build_x11) return error.NoSelectedLinuxDisplayServerProtocol;
    
    if (target.isLinux() and build_wayland) {
        const wayland_include_path = try genWaylandHeaders(b, &lib.step);
        lib.addIncludePath(.{ .path = wayland_include_path });
    }

    // collect source files
    const sources = blk: {
        var sources = std.ArrayList([]const u8).init(b.allocator);

        const source_path = path ++ "src/";

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

        if (target.isLinux()) {
            try sources.appendSlice(&linux_sources);
            if (build_wayland) try sources.appendSlice(&wayland_sources);
            if (build_x11) try sources.appendSlice(&x11_sources);
        } else if (target.isWindows()) try sources.appendSlice(&windows_sources);

        break :blk sources.items;
    };

    const flags = blk: {
        var flags = std.ArrayList([]const u8).init(b.allocator);

        const general_flags = [_][]const u8 {
            "-std=c99",
            "-D_DEFAULT_SOURCE",
            "-pedantic",
            "-Wdeclaration-after-statement",
            "-Wall",
        };

        try flags.appendSlice(&general_flags);

        if (target.isLinux()) {
            if (build_wayland) try flags.append("-D_GLFW_WAYLAND");
            if (build_x11) try flags.append("-D_GLFW_X11");
        } else if (target.isWindows()) try flags.append("-D_GLFW_WIN32");

        break :blk flags.items;
    };

    lib.addCSourceFiles(sources, flags);

    // link and include necessary deps
    lib.linkLibC();

    if (target.isLinux()) {
        if (build_wayland) lib.linkSystemLibrary("wayland-client");
        if (build_x11) lib.linkSystemLibrary("X11");
    } else if (target.isWindows()) lib.linkSystemLibrary("gdi32");

    return CLibrary {
        .include_path = path ++ "include",
        .library = lib,
    };
}

// TODO: can make more efficient once https://github.com/ziglang/zig/pull/16803 lands
fn genWaylandHeaders(b: *std.build.Builder, step: *std.build.Step) ![]const u8 {
    const protocol_path = blk: {
        var out_code: u8 = undefined;
        const protocol_path_untrimmed = b.execAllowFail(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }, &out_code, .Inherit) catch return error.WaylandProtocolsNotFound;
        break :blk std.mem.trim(u8, protocol_path_untrimmed, &std.ascii.whitespace);
    };
    const client_path = blk: {
        var out_code: u8 = undefined;
        const client_path_untrimmed = b.execAllowFail(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-client" }, &out_code, .Inherit) catch return error.WaylandClientNotFound;
        break :blk std.mem.trim(u8, client_path_untrimmed, &std.ascii.whitespace);
    };

    const header_path = try b.cache_root.join(b.allocator, &.{ "wayland-gen-headers" });

    std.fs.makeDirAbsolute(header_path) catch |err| if (err != error.PathAlreadyExists) return err;

    try genWaylandHeader(b, step, protocol_path, header_path, "stable/xdg-shell/xdg-shell.xml", "-xdg-shell");
    try genWaylandHeader(b, step, protocol_path, header_path, "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml", "-xdg-decoration");
    try genWaylandHeader(b, step, protocol_path, header_path, "stable/viewporter/viewporter.xml", "-viewporter");
    try genWaylandHeader(b, step, protocol_path, header_path, "unstable/relative-pointer/relative-pointer-unstable-v1.xml", "-relative-pointer-unstable-v1");
    try genWaylandHeader(b, step, protocol_path, header_path, "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml", "-pointer-constraints-unstable-v1");
    try genWaylandHeader(b, step, protocol_path, header_path, "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml", "-idle-inhibit-unstable-v1");
    try genWaylandHeader(b, step, client_path, header_path, "wayland.xml", "");

    return header_path;
}

fn genWaylandHeader(b: *std.build.Builder, step: *std.build.Step, protocol_path: []const u8, header_path: []const u8, xml: []const u8, out_name: []const u8) !void {
    const xml_path = b.pathJoin(&.{ protocol_path, xml });

    const out_source = b.pathJoin(&.{ header_path, try std.fmt.allocPrint(b.allocator, "wayland{s}-client-protocol-code.h", .{ out_name }) });
    try step.evalChildProcess(&.{ "wayland-scanner", "private-code", xml_path, out_source });

    const out_header = b.pathJoin(&.{ header_path, try std.fmt.allocPrint(b.allocator, "wayland{s}-client-protocol.h", .{ out_name }) });
    try step.evalChildProcess(&.{ "wayland-scanner", "client-header", xml_path, out_header });
}
