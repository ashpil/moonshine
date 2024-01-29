const std = @import("std");
const vkgen = @import("./deps/vulkan-zig/generator/index.zig");

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
    const vk = vkgen.VkGenerateStep.create(b, try b.build_root.join(b.allocator, &.{ "deps/vk.xml" })).getModule();
    const glfw = try makeGlfwLibrary(b, target);
    const cimgui = makeCImguiLibrary(b, target, glfw);
    const tinyexr = makeTinyExrLibrary(b, target);
    const default_engine_options = EngineOptions.fromCli(b);

    var exes = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);

    // TODO: make custom test runner parallel + share some state across tests
    try exes.append(blk: {
        var engine_options = default_engine_options;
        engine_options.window = false;
        engine_options.gui = false;
        const engine = makeEngineModule(b, vk, engine_options);

        const tests = b.addTest(.{
            .name = "tests",
            .root_source_file = .{ .path = "engine/tests.zig" },
            .test_runner = "engine/test_runner.zig",
            .target = target,
            .optimize = optimize,
        });
        tests.root_module.addImport("vulkan", vk);
        tests.root_module.addImport("engine", engine);

        break :blk tests;
    });

    // online exe
    try exes.append(blk: {
        var engine_options = default_engine_options;
        engine_options.vk_metrics = true;
        engine_options.shader_source = .load; // for hot shader reload
        const engine = makeEngineModule(b, vk, engine_options);
        const exe = b.addExecutable(.{
            .name = "online",
            .root_source_file = .{ .path = "online/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("vulkan", vk);
        exe.root_module.addImport("engine", engine);
        glfw.add(&exe.root_module);
        glfw.add(engine);
        tinyexr.add(&exe.root_module);
        tinyexr.add(engine);
        cimgui.add(&exe.root_module);
        cimgui.add(engine);

        break :blk exe;
    });

    // offline exe
    try exes.append(blk: {
        var engine_options = default_engine_options;
        engine_options.window = false;
        engine_options.gui = false;
        const engine = makeEngineModule(b, vk, engine_options);
        const exe = b.addExecutable(.{
            .name = "offline",
            .root_source_file = .{ .path = "offline/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("vulkan", vk);
        exe.root_module.addImport("engine", engine);
        tinyexr.add(&exe.root_module);
        tinyexr.add(engine);

        break :blk exe;
    });

    // create run step for all exes
    for (exes.items) |exe| {
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);

        const step_name = try std.fmt.allocPrint(b.allocator, "run-{s}", .{ exe.name });
        const step_description = try std.fmt.allocPrint(b.allocator, "Run {s}", .{ exe.name });
        const step = b.step(step_name, step_description);
        step.dependOn(&run.step);
    }

    // create install step for all exes
    for (exes.items) |exe| {
        const install = b.addInstallArtifact(exe, .{});

        const step_name = try std.fmt.allocPrint(b.allocator, "install-{s}", .{ exe.name });
        const step_description = try std.fmt.allocPrint(b.allocator, "Install {s}", .{ exe.name });
        const step = b.step(step_name, step_description);
        step.dependOn(&install.step);
    }

    // create check step that type-checks all exes
    // probably does a bit more atm but what can you do
    const check_step = b.step("check", "Type check all");
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

    fn fromCli(b: *std.Build) EngineOptions {
        var options = EngineOptions {};

        if (b.option(bool, "vk-validation", "Enable vulkan validation")) |vk_validation| {
            options.vk_validation = vk_validation;
        }

        return options;
    }
};

fn makeEngineModule(b: *std.Build, vk: *std.Build.Module, options: EngineOptions) *std.Build.Module {
    const zgltf = b.createModule(.{ .root_source_file = .{ .path = "deps/zgltf/src/main.zig" } });
    const zigimg = b.createModule(.{ .root_source_file = .{ .path = "deps/zigimg/zigimg.zig" } });

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

    var imports = std.ArrayList(std.Build.Module.Import).init(b.allocator);

    imports.appendSlice(&.{
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
    }) catch @panic("OOM");

    // embed shaders even if options.shader_source == .load so that
    // initial shader correctness is checked at compile time even
    // if runtime modification is allowed
    const rt_shader_comp = vkgen.ShaderCompileStep.create(b, &rt_shader_compile_cmd, "-Fo");
    rt_shader_comp.step.name = "Compile ray tracing shaders";
    rt_shader_comp.add("@\"hrtsystem/input.hlsl\"", "shaders/hrtsystem/input.hlsl", .{});
    rt_shader_comp.add("@\"hrtsystem/main.hlsl\"", "shaders/hrtsystem/main.hlsl", .{
        .watched_files = &.{
            "shaders/hrtsystem/camera.hlsl",
            "shaders/hrtsystem/world.hlsl",
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
    compute_shader_comp.step.name = "Compile compute shaders";

    imports.appendSlice(&.{
        .{
            .name = "rt_shaders",
            .module = rt_shader_comp.getModule(),
        },
        .{
            .name = "compute_shaders",
            .module = compute_shader_comp.getModule(),
        },
    }) catch @panic("OOM");

    const module = b.createModule(.{
        .root_source_file = .{ .path = "engine/engine.zig" },
        .imports = imports.items,
    });

    module.link_libc = true; // always needed to load vulkan

    return module;
}

const CLibrary = struct {
    include_path: []const u8,
    library: *std.Build.Step.Compile,

    fn add(self: CLibrary, module: *std.Build.Module) void {
        module.linkLibrary(self.library);
        module.addIncludePath(.{ .path = self.include_path });
    }
};

fn makeCImguiLibrary(b: *std.Build, target: std.Build.ResolvedTarget, glfw: CLibrary) CLibrary {
    const path = "./deps/cimgui/";

    const lib = b.addStaticLibrary(.{
        .name = "cimgui",
        .target = target,
        .optimize = .ReleaseFast,
    });
    lib.linkLibCpp();
    lib.addCSourceFiles(.{
        .files = &.{
            path ++ "cimgui.cpp",
            path ++ "imgui/imgui.cpp",
            path ++ "imgui/imgui_draw.cpp",
            path ++ "imgui/imgui_demo.cpp",
            path ++ "imgui/imgui_widgets.cpp",
            path ++ "imgui/imgui_tables.cpp",
            path ++ "imgui/backends/imgui_impl_glfw.cpp",
        }, .flags = &.{
            "-DGLFW_INCLUDE_NONE",
            "-DIMGUI_IMPL_API=extern \"C\"",
        }
    });
    lib.addIncludePath(.{ .path = path ++ "imgui/" });
    lib.addIncludePath(.{ .path = glfw.include_path });

    return CLibrary {
        .include_path = path,
        .library = lib,
    };
}

fn makeTinyExrLibrary(b: *std.Build, target: std.Build.ResolvedTarget) CLibrary {
    const tinyexr_path = "./deps/tinyexr/";
    const miniz_path = tinyexr_path ++ "deps/miniz/";

    const lib = b.addStaticLibrary(.{
        .name = "tinyexr",
        .target = target,
        .optimize = .ReleaseFast,
    });
    lib.linkLibCpp();
    lib.addIncludePath(.{ .path = miniz_path });
    lib.addCSourceFiles(.{
        .files = &.{
            tinyexr_path ++ "tinyexr.cc",
            miniz_path ++ "miniz.c",
        },
    });

    return CLibrary {
        .include_path = tinyexr_path,
        .library = lib,
    };
}

fn makeGlfwLibrary(b: *std.Build, target: std.Build.ResolvedTarget) !CLibrary {
    const path = "./deps/glfw/";
    const lib = b.addStaticLibrary(.{
        .name = "glfw",
        .target = target,
        .optimize = .ReleaseFast,
    });

    const build_wayland = b.option(bool, "wayland", "Support Wayland on Linux. (default: true)") orelse true;
    const build_x11 = b.option(bool, "x11", "Support X11 on Linux. (default: true)") orelse true;

    if (!build_wayland and !build_x11) return error.NoSelectedLinuxDisplayServerProtocol;

    if (target.result.os.tag == .linux and build_wayland) {
        const wayland_include_path = generateWaylandHeaders(b);
        lib.addIncludePath(wayland_include_path);
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

    lib.addCSourceFiles(.{ .files = sources, .flags = flags });

    // link and include necessary deps
    lib.linkLibC();

    if (target.result.os.tag == .linux) {
        if (build_wayland) lib.linkSystemLibrary("wayland-client");
        if (build_x11) lib.linkSystemLibrary("X11");
    } else if (target.result.os.tag == .windows) lib.linkSystemLibrary("gdi32");

    return CLibrary {
        .include_path = path ++ "include",
        .library = lib,
    };
}

fn generateWaylandHeaders(b: *std.Build) std.Build.LazyPath {
    // ignore pkg-config errors -- this'll make wayland-scanner error down the road,
    // but it'll mean that when glfw isn't actually being used we won't error on
    // missing wayland
    const protocol_path = blk: {
        var out_code: u8 = undefined;
        const protocol_path_untrimmed = b.runAllowFail(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }, &out_code, .Inherit) catch "";
        break :blk std.mem.trim(u8, protocol_path_untrimmed, &std.ascii.whitespace);
    };
    const client_path = blk: {
        var out_code: u8 = undefined;
        const client_path_untrimmed = b.runAllowFail(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-client" }, &out_code, .Inherit) catch "";
        break :blk std.mem.trim(u8, client_path_untrimmed, &std.ascii.whitespace);
    };

    const write_file_step = b.addWriteFiles();
    write_file_step.step.name = "Write Wayland headers";

    generateWaylandHeader(b, write_file_step, protocol_path, "stable/xdg-shell/xdg-shell.xml", "-xdg-shell");
    generateWaylandHeader(b, write_file_step, protocol_path, "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml", "-xdg-decoration");
    generateWaylandHeader(b, write_file_step, protocol_path, "stable/viewporter/viewporter.xml", "-viewporter");
    generateWaylandHeader(b, write_file_step, protocol_path, "unstable/relative-pointer/relative-pointer-unstable-v1.xml", "-relative-pointer-unstable-v1");
    generateWaylandHeader(b, write_file_step, protocol_path, "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml", "-pointer-constraints-unstable-v1");
    generateWaylandHeader(b, write_file_step, protocol_path, "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml", "-idle-inhibit-unstable-v1");
    generateWaylandHeader(b, write_file_step, client_path, "wayland.xml", "");

    return write_file_step.getDirectory();
}

fn generateWaylandHeader(b: *std.Build, write_file_step: *std.Build.Step.WriteFile, protocol_path: []const u8, xml: []const u8, out_name: []const u8) void {
    const xml_path = b.pathJoin(&.{ protocol_path, xml });

    const out_source_name = std.fmt.allocPrint(b.allocator, "wayland{s}-client-protocol-code.h", .{ out_name }) catch @panic("OOM");
    const gen_private_code_step = b.addSystemCommand(&.{ "wayland-scanner", "private-code", xml_path });
    const out_source = gen_private_code_step.addOutputFileArg(out_source_name);
    _ = write_file_step.addCopyFile(out_source, out_source_name);

    const out_header_name = std.fmt.allocPrint(b.allocator, "wayland{s}-client-protocol.h", .{ out_name }) catch @panic("OOM");
    const gen_client_header_step = b.addSystemCommand(&.{ "wayland-scanner", "client-header", xml_path });
    const out_header = gen_client_header_step.addOutputFileArg(out_header_name);
    _ = write_file_step.addCopyFile(out_header, out_header_name);
}
