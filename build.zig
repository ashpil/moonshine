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
    const tinyexr = makeTinyExrLibrary(b, target);
    const zgltf = b.createModule(.{
        .source_file = .{ .path = "deps/zgltf/src/main.zig" },
    });
    const zigimg = b.createModule(.{
        .source_file = .{ .path = "deps/zigimg/zigimg.zig" },
    });
    const default_engine_options = EngineOptions.fromCli(b);

    {
        var engine_options = default_engine_options;
        const engine = makeEnginePackage(b, vk, zgltf, zigimg, engine_options) catch unreachable;

        const engine_tests = b.addTest(.{
            .name = "test",
            .root_source_file = .{ .path = "engine/tests.zig" },
            .kind = .test_exe,
            .target = target,
            .optimize = optimize,
        });
        engine_tests.install();
        engine_tests.addModule("vulkan", vk);
        engine_tests.addModule("engine", engine);

        engine_tests.linkLibC();
        engine_tests.linkLibrary(tinyexr.library);
        engine_tests.addIncludePath(tinyexr.include_path);

        const run_test_cmd = engine_tests.run();
        run_test_cmd.step.dependOn(b.getInstallStep());

        const test_step = b.step("test", "Run engine tests");
        test_step.dependOn(&run_test_cmd.step);
    }

    // online exe
    {
        var engine_options = default_engine_options;
        engine_options.windowing = true;
        const engine = makeEnginePackage(b, vk, zgltf, zigimg, engine_options) catch unreachable;
        const online_exe = b.addExecutable(.{
            .name = "online",
            .root_source_file = .{ .path = "online/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        online_exe.install();

        online_exe.addModule("vulkan", vk);
        online_exe.addModule("engine", engine);
        online_exe.linkLibrary(glfw.library);
        online_exe.addIncludePath(glfw.include_path);
        online_exe.linkLibC();
        online_exe.linkLibrary(tinyexr.library);
        online_exe.addIncludePath(tinyexr.include_path);

        const run_online = online_exe.run();
        run_online.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_online.addArgs(args);
        }

        b.step("run-online", "Run online").dependOn(&run_online.step);
    }

    // offline exe
    {
        var engine_options = default_engine_options;
        engine_options.windowing = false;
        const engine = makeEnginePackage(b, vk, zgltf, zigimg, engine_options) catch unreachable;
        const offline_exe = b.addExecutable(.{
            .name = "offline",
            .root_source_file = .{ .path = "offline/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        offline_exe.install();

        offline_exe.addModule("vulkan", vk);
        offline_exe.addModule("engine", engine);
        offline_exe.linkLibC();
        offline_exe.linkLibrary(tinyexr.library);
        offline_exe.addIncludePath(tinyexr.include_path);

        const run_offline = offline_exe.run();
        run_offline.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_offline.addArgs(args);
        }

        b.step("run-offline", "Run offline").dependOn(&run_offline.step);
    }
}

pub const EngineOptions = struct {
    vk_validation: bool = false,
    vk_measure_perf: bool = false,
    windowing: bool = false,

    fn fromCli(b: *std.build.Builder) EngineOptions {
        var options = EngineOptions {};

        if (b.option(bool, "vk-validation", "Enable vulkan validation")) |vk_validation| {
            options.vk_validation = vk_validation;
        }

        if (b.option(bool, "vk-measure-perf", "Report frame times")) |vk_measure_perf| {
            options.vk_measure_perf = vk_measure_perf;
        }

        return options;
    }
};

fn makeEnginePackage(b: *std.build.Builder, vk: *std.build.Module, zgltf: *std.build.Module, zigimg: *std.build.Module, options: EngineOptions) !*std.build.Module {
    // hlsl
    const hlsl_shader_cmd = [_][]const u8 {
        "dxc",
        "-T", "lib_6_7",
        "-HV", "2021",
        "-spirv",
        "-fspv-target-env=vulkan1.3",
        "-fvk-use-scalar-layout",
        "-Ges", // strict mode
        "-WX", // treat warnings as errors
    };
    const hlsl_comp = vkgen.ShaderCompileStep.create(b, &hlsl_shader_cmd, "-Fo");
    hlsl_comp.add("input", "shaders/misc/input.hlsl", .{});
    hlsl_comp.add("main", "shaders/primary/main.hlsl", .{
        .watched_files = &.{
            "shaders/primary/bindings.hlsl",
            "shaders/primary/camera.hlsl",
            "shaders/primary/geometry.hlsl",
            "shaders/primary/integrator.hlsl",
            "shaders/primary/intersection.hlsl",
            "shaders/primary/light.hlsl",
            "shaders/primary/material.hlsl",
            "shaders/primary/math.hlsl",
            "shaders/primary/random.hlsl",
            "shaders/primary/reflection_frame.hlsl",
        }
    });

    // actual engine
    const build_options = b.addOptions();
    build_options.addOption(bool, "vk_validation", options.vk_validation);
    build_options.addOption(bool, "vk_measure_perf", options.vk_measure_perf);
    build_options.addOption(bool, "windowing", options.windowing);

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
                .name = "shaders",
                .module = hlsl_comp.getModule(),
            },
        },
    });
}

const CLibrary = struct {
    include_path: []const u8,
    library: *std.build.LibExeObjStep,
};

fn makeTinyExrLibrary(b: *std.build.Builder, target: std.zig.CrossTarget) CLibrary {
    const tinyexr_path = "./deps/tinyexr/";
    const miniz_path = tinyexr_path ++ "deps/miniz/";

    const lib = b.addStaticLibrary(.{
        .name = "tinyexr",
        .target = target,
        .optimize = .ReleaseFast,
    });
    lib.linkLibCpp();
    lib.addIncludePath(miniz_path);
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

    const maybe_lws = b.option([]const u8, "target-lws", "Target linux window system to use, omit to build all.\n                               Ignored for Windows builds. (options: X11, Wayland)");
    var lws: Lws = .all;
    if (maybe_lws) |str_lws| {
        if (std.mem.eql(u8, str_lws, "Wayland")) {
            try genWaylandHeaders(b, &lib.step);
            lib.addIncludePath("./zig-cache/wayland-gen-headers/");
            lws = .wayland;
        } else if (std.mem.eql(u8, str_lws, "X11")) {
            lws = .x11;
        } else {
            return error.UnsupportedLinuxWindowSystem;
        }
    } else if (target.isLinux()) {
        try genWaylandHeaders(b, &lib.step);
        lib.addIncludePath("./zig-cache/wayland-gen-headers/");
    }

    // collect source files
    var sources = std.ArrayList([]const u8).init(b.allocator);
    {
        const source_path = path ++ "src/";

        const general_sources = [_][]const u8 {
            "context.c",
            "init.c",
            "input.c",
            "monitor.c",
            "vulkan.c",
            "window.c",
            "egl_context.c",
            "osmesa_context.c",
            "platform.c",
            "null_init.c",
            "null_window.c",
            "null_joystick.c",
            "null_monitor.c",
            "null_monitor.c",
        };

        const linux_sources = [_][]const u8 {
            "posix_time.c",
            "posix_thread.c",
            "posix_module.c",
            "posix_poll.c",
            "xkb_unicode.c",
            "linux_joystick.c",
        };

        const x11_sources = [_][]const u8 {
            "x11_init.c",
            "x11_monitor.c",
            "x11_window.c",
            "glx_context.c",
        };

        const wayland_sources = [_][]const u8 {
            "wl_init.c",
            "wl_monitor.c",
            "wl_window.c",
        };

        const windows_sources = [_][]const u8 {
            "win32_thread.c",
            "wgl_context.c",
            "win32_init.c",
            "win32_monitor.c",
            "win32_time.c",
            "win32_joystick.c",
            "win32_window.c",
            "win32_module.c",
        };

        inline for (general_sources) |source| {
            try sources.append(source_path ++ source);
        }

        if (target.isLinux()) {
            inline for (linux_sources) |source| {
                try sources.append(source_path ++ source);
            }
            switch (lws) {
                .all => {
                    inline for (x11_sources ++ wayland_sources) |source| {
                        try sources.append(source_path ++ source);
                    }
                },
                .x11 => {
                    inline for (x11_sources) |source| {
                        try sources.append(source_path ++ source);
                    }
                },
                .wayland => {
                    inline for (wayland_sources) |source| {
                        try sources.append(source_path ++ source);
                    }
                }
            }
        } else if (target.isWindows()) {
            inline for (windows_sources) |source| {
                try sources.append(source_path ++ source);
            }
        }
    }

    var flags = std.ArrayList([]const u8).init(b.allocator);

    const general_flags = [_][]const u8 {
        "-std=c99",
        "-D_DEFAULT_SOURCE",
        "-pedantic",
        "-Wdeclaration-after-statement",
        "-Wall",
    };

    inline for (general_flags) |flag| {
        try flags.append(flag);
    }

    if (target.isLinux()) {
        switch (lws) {
            .all => {
                try flags.append("-D_GLFW_X11");
                try flags.append("-D_GLFW_WAYLAND");
                try flags.append("-I./zig-cache/wayland-gen-headers/");
            },
            .x11 => try flags.append("-D_GLFW_X11"),
            .wayland => { 
                try flags.append("-D_GLFW_WAYLAND");
                try flags.append("-I./zig-cache/wayland-gen-headers/");
            }
        }
    } else {
        try flags.append("-D_GLFW_WIN32");
    }

    lib.addCSourceFiles(sources.items, flags.items);

    // link necessary deps
    lib.linkLibC();

    if (target.isLinux()) {
        switch (lws) {
            .all => {
                lib.linkSystemLibrary("X11");
                lib.linkSystemLibrary("wayland-client");
            },
            .x11 => lib.linkSystemLibrary("X11"),
            .wayland => lib.linkSystemLibrary("wayland-client"),
        }
    } else if (target.isWindows()) {
        lib.linkSystemLibrary("gdi32"); 
    }

    return CLibrary {
        .include_path = path ++ "include",
        .library = lib,
    };
}

const Lws = enum {
    wayland,
    x11,
    all,
};

fn genWaylandHeader(b: *std.build.Builder, step: *std.build.Step, protocol_path: []const u8, header_path: []const u8, xml: []const u8, out_name: []const u8) !void {
    const xml_path = try std.fs.path.join(b.allocator, &[_][]const u8{
        protocol_path,
        xml,
    });

    const out_source = try std.fs.path.join(b.allocator, &[_][]const u8{
        header_path,
        try std.fmt.allocPrint(b.allocator, "wayland-{s}-client-protocol-code.h", .{out_name}),
    });

    const out_header = try std.fs.path.join(b.allocator, &[_][]const u8{
        header_path,
        try std.fmt.allocPrint(b.allocator, "wayland-{s}-client-protocol.h", .{out_name}),
    });

    const source_cmd = b.addSystemCommand(&[_][]const u8 {
        "wayland-scanner", "private-code", xml_path, out_source,
    });

    const header_cmd = b.addSystemCommand(&[_][]const u8 {
        "wayland-scanner", "client-header", xml_path, out_header,
    });

    step.dependOn(&source_cmd.step);
    step.dependOn(&header_cmd.step);
}

fn genWaylandHeaders(b: *std.build.Builder, step: *std.build.Step) !void {
    const pkg_config_protocols_result = try std.ChildProcess.exec(.{
        .allocator = b.allocator,
        .argv =  &[_][]const u8 {
            "pkg-config", "wayland-protocols", "--variable=pkgdatadir"
        },
    });

    if (pkg_config_protocols_result.term == .Exited and pkg_config_protocols_result.term.Exited != 0) {
        return error.WaylandProtocolsNotFound;
    }

    const protocol_path = std.mem.trimRight(u8, pkg_config_protocols_result.stdout, " \n");

    const header_path = try b.cache_root.join(
        b.allocator,
        &.{"wayland-gen-headers"},
    );

    if (std.fs.makeDirAbsolute(header_path)) |_| {
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    }

    try genWaylandHeader(b, step, protocol_path, header_path, "stable/xdg-shell/xdg-shell.xml", "xdg-shell");
    try genWaylandHeader(b, step, protocol_path, header_path, "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml", "xdg-decoration");
    try genWaylandHeader(b, step, protocol_path, header_path, "stable/viewporter/viewporter.xml", "viewporter");
    try genWaylandHeader(b, step, protocol_path, header_path, "unstable/relative-pointer/relative-pointer-unstable-v1.xml", "relative-pointer-unstable-v1");
    try genWaylandHeader(b, step, protocol_path, header_path, "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml", "pointer-constraints-unstable-v1");
    try genWaylandHeader(b, step, protocol_path, header_path, "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml", "idle-inhibit-unstable-v1");

    {
        const pkg_config_wayland_result = try std.ChildProcess.exec(.{
            .allocator = b.allocator,
            .argv =  &[_][]const u8 {
                "pkg-config", "wayland-client", "--variable=pkgdatadir"
            },
        });

        if (pkg_config_wayland_result.term == .Exited and pkg_config_wayland_result.term.Exited != 0) {
            return error.WaylandClientNotFound;
        }

        const wayland_path = std.mem.trimRight(u8, pkg_config_wayland_result.stdout, " \n");
        const wayland_xml_path = try std.fs.path.join(b.allocator, &[_][]const u8{
            wayland_path,
            "wayland.xml",
        });

        {
            const out_source = try std.fs.path.join(b.allocator, &[_][]const u8{
                header_path,
                "wayland-client-protocol-code.h",
            });
            const source_cmd = b.addSystemCommand(&[_][]const u8 {
                "wayland-scanner", "private-code", wayland_xml_path, out_source,
            });
            step.dependOn(&source_cmd.step);
        }
       
        {
            const out_header = try std.fs.path.join(b.allocator, &[_][]const u8{
                header_path,
                "wayland-client-protocol.h",
            });

            const header_cmd = b.addSystemCommand(&[_][]const u8 {
                "wayland-scanner", "client-header", wayland_xml_path, out_header,
            });

            step.dependOn(&header_cmd.step);
        }
    }
}
