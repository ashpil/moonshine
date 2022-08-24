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
    const mode = b.standardReleaseOptions();

    // packages/libraries we'll need below
    const vk = vkgen.VkGenerateStep.init(b, "./deps/vk.xml", "vk.zig").package;
    const glfw = makeGlfwLibrary(b, "./deps/glfw/", target, mode) catch unreachable;
    const engine = makeEnginePackage(b, vk) catch unreachable;

    // chess exe
    {
        const rtchess_exe = b.addExecutable("rtchess", "rtchess/main.zig");
        rtchess_exe.setTarget(target);
        rtchess_exe.setBuildMode(mode);
        rtchess_exe.install();

        rtchess_exe.addPackage(vk);
        rtchess_exe.addPackage(engine);
        rtchess_exe.linkLibrary(glfw);

        const run_chess = rtchess_exe.run();
        run_chess.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_chess.addArgs(args);
        }

        b.step("run-chess", "Run chess").dependOn(&run_chess.step);
    }
}

fn makeEnginePackage(b: *std.build.Builder, vk: std.build.Pkg) !std.build.Pkg {
    // hlsl
    const hlsl_shader_cmd = [_][]const u8 {
        "dxc",
        "-T", "lib_6_7",
        "-spirv",
        "-fspv-target-env=vulkan1.2",
        "-fvk-use-scalar-layout",
    };
    const hlsl_comp = HlslCompileStep.init(b, &hlsl_shader_cmd, "");
    hlsl_comp.add("input", "shaders/misc/input.hlsl");
    hlsl_comp.add("raygen", "shaders/primary/shader.rgen.hlsl");
    hlsl_comp.add("rayhit", "shaders/primary/shader.rchit.hlsl");
    hlsl_comp.add("raymiss", "shaders/primary/shader.rmiss.hlsl");
    hlsl_comp.add("shadowmiss", "shaders/primary/shadow.rmiss.hlsl");

    // actual engine
    const build_options = b.addOptions();
    build_options.addOption(bool, "vk_enable_validation", false);
    build_options.addOption(bool, "vk_measure_perf", false);

    const deps_local = [_]std.build.Pkg {
        vk,
        build_options.getPackage("build_options"),
        hlsl_comp.package,
    };

    const engine_deps = try b.allocator.create([deps_local.len]std.build.Pkg);
    engine_deps.* = deps_local;

    const engine = std.build.Pkg{
        .name = "engine",
        .source = .{ .path = "engine/engine.zig" },
        .dependencies = engine_deps,
    };

    return engine;
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
        try std.fmt.allocPrint(b.allocator, "wayland-{s}-client-protocol.c", .{out_name}),
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
    const pkg_config_result = try std.ChildProcess.exec(.{
        .allocator = b.allocator,
        .argv =  &[_][]const u8 {
            "pkg-config", "wayland-protocols", "--variable=pkgdatadir"
        },
    });

    if (pkg_config_result.term == .Exited and pkg_config_result.term.Exited != 0) {
        return error.WaylandProtocolsNotFound;
    }

    const protocol_path = std.mem.trimRight(u8, pkg_config_result.stdout, " \n");

    const cache_dir = try std.fs.path.join(b.allocator, &[_][]const u8{
        b.build_root,
        b.cache_root,
    });
    const header_path = try std.fs.path.join(b.allocator, &[_][]const u8{
        cache_dir,
        "wayland-gen-headers",
    });

    const header_mkdir = std.fs.makeDirAbsolute(header_path);
    if (header_mkdir) |_| {
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
}

// adapted from mach glfw
fn makeGlfwLibrary(b: *std.build.Builder, comptime dir: []const u8, target: std.zig.CrossTarget, mode: std.builtin.Mode) !*std.build.LibExeObjStep {
    const lib = b.addStaticLibrary("glfw", null);
    lib.setBuildMode(mode);
    lib.setTarget(target);

    const maybe_lws = b.option([]const u8, "target-lws", "Target linux window system to use, omit to build all.\n                               Ignored for Windows builds. (options: X11, Wayland)");
    var lws: Lws = .all;
    if (maybe_lws) |str_lws| {
        if (std.mem.eql(u8, str_lws, "Wayland")) {
            try genWaylandHeaders(b, &lib.step);
            lws = .wayland;
        } else if (std.mem.eql(u8, str_lws, "X11")) {
            lws = .x11;
        } else {
            return error.UnsupportedLinuxWindowSystem;
        }
    } else if (target.isLinux()) {
        try genWaylandHeaders(b, &lib.step);
    }

    // collect source files
    var sources = std.ArrayList([]const u8).init(b.allocator);
    {
        const source_dir = dir ++ "src/";

        const general_sources = [_][]const u8 {
            "context.c",
            "init.c",
            "input.c",
            "monitor.c",
            "vulkan.c",
            "window.c",
            "egl_context.c",
            "osmesa_context.c",
        };

        const linux_sources = [_][]const u8 {
            "posix_time.c",
            "posix_thread.c",
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
        };

        const wayland_lib_sources = [_][]const u8 {
            "./zig-cache/wayland-gen-headers/wayland-idle-inhibit-unstable-v1-client-protocol.c",
            "./zig-cache/wayland-gen-headers/wayland-pointer-constraints-unstable-v1-client-protocol.c",
            "./zig-cache/wayland-gen-headers/wayland-relative-pointer-unstable-v1-client-protocol.c",
            "./zig-cache/wayland-gen-headers/wayland-viewporter-client-protocol.c",
            "./zig-cache/wayland-gen-headers/wayland-xdg-decoration-client-protocol.c",
            "./zig-cache/wayland-gen-headers/wayland-xdg-shell-client-protocol.c",
        };

        inline for (general_sources) |source| {
            try sources.append(source_dir ++ source);
        }

        if (target.isLinux()) {
            inline for (linux_sources) |source| {
                try sources.append(source_dir ++ source);
            }
            switch (lws) {
                .all => {
                    inline for (x11_sources ++ wayland_sources) |source| {
                        try sources.append(source_dir ++ source);
                    }
                    inline for (wayland_lib_sources) |source| {
                        try sources.append(source);
                    }
                },
                .x11 => {
                    inline for (x11_sources) |source| {
                        try sources.append(source_dir ++ source);
                    }
                },
                .wayland => {
                    inline for (wayland_sources) |source| {
                        try sources.append(source_dir ++ source);
                    }
                    inline for (wayland_lib_sources) |source| {
                        try sources.append(source);
                    }
                }
            }
        } else if (target.isWindows()) {
            inline for (windows_sources) |source| {
                try sources.append(source_dir ++ source);
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

    // includes
    lib.addIncludePath(dir ++ "include");

    return lib;
}

// adapted from vk-zig
pub const HlslCompileStep = struct {
    const Shader = struct {
        source_path: []const u8,
        full_out_path: []const u8,
    };

    step: std.build.Step,
    builder: *std.build.Builder,
    cmd: []const []const u8,
    output_dir: []const u8,
    shaders: std.ArrayList(Shader),
    file_text: std.ArrayList(u8),
    package: std.build.Pkg,
    output_file: std.build.GeneratedFile,

    pub fn init(builder: *std.build.Builder, cmd: []const []const u8, output_dir: []const u8) *HlslCompileStep {
        const full_out_path = std.fs.path.join(builder.allocator, &[_][]const u8{
            builder.build_root,
            builder.cache_root,
            "shaders.zig",
        }) catch unreachable;

        const self = builder.allocator.create(HlslCompileStep) catch unreachable;
        self.* = .{
            .step = std.build.Step.init(.custom, "shader-compile", builder.allocator, make),
            .builder = builder,
            .output_dir = output_dir,
            .cmd = builder.dupeStrings(cmd),
            .shaders = std.ArrayList(Shader).init(builder.allocator),
            .file_text = std.ArrayList(u8).init(builder.allocator),
            .package = .{
                .name = "shaders",
                .source = .{ .generated = &self.output_file },
                .dependencies = null,
            },
            .output_file = .{
                .step = &self.step,
                .path = full_out_path,
            },
        };
        return self;
    }

    pub fn add(self: *HlslCompileStep, import_name: []const u8, src: []const u8) void {
        const output_filename = std.fmt.allocPrint(self.builder.allocator, "{s}.spv", .{ src }) catch unreachable;
        const full_out_path = std.fs.path.join(self.builder.allocator, &[_][]const u8{
            self.builder.build_root,
            self.builder.cache_root,
            self.output_dir,
            output_filename,
        }) catch unreachable;
        self.shaders.append(.{ .source_path = src, .full_out_path = full_out_path }) catch unreachable;

        self.file_text.writer().print("pub const {s} = @embedFile(\"{s}\");\n", .{ import_name, full_out_path }) catch unreachable;
    }

    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(HlslCompileStep, "step", step);
        const cwd = std.fs.cwd();

        const cmd = try self.builder.allocator.alloc([]const u8, self.cmd.len + 3);
        for (self.cmd) |part, i| {
            cmd[i] = part;
        }
        cmd[cmd.len - 2] = "-Fo";

        for (self.shaders.items) |shader| {
            const dir = std.fs.path.dirname(shader.full_out_path).?;
            try cwd.makePath(dir);
            cmd[cmd.len - 3] = shader.source_path;
            cmd[cmd.len - 1] = shader.full_out_path;
            try self.builder.spawnChild(cmd);
        }

        const dir = std.fs.path.dirname(self.output_file.path.?).?;
        try cwd.makePath(dir);
        try cwd.writeFile(self.output_file.path.?, self.file_text.items);
    }
};

