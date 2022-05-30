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

    const exe = b.addExecutable("chess_rtx", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    // vulkan bindings
    const gen = vkgen.VkGenerateStep.init(b, "./deps/vk.xml", "vk.zig");
    exe.addPackage(gen.package);

    // glfw stuff
    const glfw_dir = "./deps/glfw/";
    const glfw = createGlfwLib(b, glfw_dir, target, mode, exe) catch unreachable;
    exe.linkLibrary(glfw);
    exe.addIncludeDir(glfw_dir ++ "include");
    
    const shader_cmd = [_][]const u8 {
        "glslc",
        "--target-env=vulkan1.2",
        if (mode == .Debug) "-g" else "-O",
    };
    const shader_comp = vkgen.ShaderCompileStep.init(b, &shader_cmd, "");
    exe.step.dependOn(&shader_comp.step);

    _ = shader_comp.add("shaders/primary/shader.rgen");
    _ = shader_comp.add("shaders/primary/shader.rchit");
    _ = shader_comp.add("shaders/primary/shader.rmiss");
    _ = shader_comp.add("shaders/primary/shadow.rmiss");

    _ = shader_comp.add("shaders/misc/input.rgen");
    _ = shader_comp.add("shaders/misc/input.rchit");
    _ = shader_comp.add("shaders/misc/input.rmiss");

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

const Lws = enum {
    wayland,
    x11,
    all,
};

// 
//generate() {
//  protocol_path=$1
//  output_name=$2
//
//  rm -f "$gen_dir"/wayland-"$output_name"-client-protocol.{h,c}
//
//  wayland-scanner private-code wayland-protocols/"$protocol_path".xml "$gen_dir"/wayland-"$output_name"-client-protocol.c
//  wayland-scanner client-header wayland-protocols/"$protocol_path".xml "$gen_dir"/wayland-"$output_name"-client-protocol.h
//}

fn genWaylandHeader(b: *std.build.Builder, exe: *std.build.LibExeObjStep, protocol_path: []const u8, header_path: []const u8, xml: []const u8, out_name: []const u8) !void {
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

    exe.step.dependOn(&source_cmd.step);
    exe.step.dependOn(&header_cmd.step);
}

fn genWaylandHeaders(b: *std.build.Builder, exe: *std.build.LibExeObjStep) !void {
    const clone_path = try std.fs.path.join(b.allocator, &[_][]const u8{
        b.build_root,
        b.cache_root,
    });

    const protocol_path = try std.fs.path.join(b.allocator, &[_][]const u8{
        clone_path,
        "wayland-protocols"
    });

    const header_path = try std.fs.path.join(b.allocator, &[_][]const u8{
        clone_path,
        "wayland-gen-headers",
    });

    if (std.fs.openDirAbsolute(protocol_path, .{})) |_| {
        const protocol_pull = b.addSystemCommand(&[_][]const u8 {
            "git", "-C", protocol_path, "pull", "--quiet"
        });
        exe.step.dependOn(&protocol_pull.step);
    } else |_| {
        const protocol_clone = b.addSystemCommand(&[_][]const u8 {
            "git", "-C", clone_path, "clone", "https://github.com/wayland-project/wayland-protocols"
        });
        const mkdir = b.addSystemCommand(&[_][]const u8 {
            "mkdir", header_path,
        });
        exe.step.dependOn(&protocol_clone.step);
        exe.step.dependOn(&mkdir.step);
    }

    try genWaylandHeader(b, exe, protocol_path, header_path, "stable/xdg-shell/xdg-shell.xml", "xdg-shell");
    try genWaylandHeader(b, exe, protocol_path, header_path, "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml", "xdg-decoration");
    try genWaylandHeader(b, exe, protocol_path, header_path, "stable/viewporter/viewporter.xml", "viewporter");
    try genWaylandHeader(b, exe, protocol_path, header_path, "unstable/relative-pointer/relative-pointer-unstable-v1.xml", "relative-pointer-unstable-v1");
    try genWaylandHeader(b, exe, protocol_path, header_path, "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml", "pointer-constraints-unstable-v1");
    try genWaylandHeader(b, exe, protocol_path, header_path, "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml", "idle-inhibit-unstable-v1");
}

// adapted from mach glfw
fn createGlfwLib(b: *std.build.Builder, comptime dir: []const u8, target: std.zig.CrossTarget, mode: std.builtin.Mode, exe: *std.build.LibExeObjStep) !*std.build.LibExeObjStep {
    const maybe_lws = b.option([]const u8, "target-lws", "Target linux window system to use, omit to build all.\n                               Ignored for Windows builds. (options: X11, Wayland)");
    var lws: Lws = undefined;
    if (maybe_lws) |str_lws| {
        if (std.mem.eql(u8, str_lws, "Wayland")) {
            try genWaylandHeaders(b, exe);
            lws = .wayland;
        } else if (std.mem.eql(u8, str_lws, "X11")) {
            lws = .x11;
        } else {
            return error.unsupportedLinuxWindowSystem;
        }
    } else {
        try genWaylandHeaders(b, exe);
        lws = .all;
    }

    const lib = b.addStaticLibrary("glfw", null);
    lib.setBuildMode(mode);
    lib.setTarget(target);

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
        try flags.append("-GLFW_WIN32");
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
            .wayland => {
                lib.linkSystemLibrary("wayland-client");
                lib.linkSystemLibrary("wayland-cursor");
                lib.linkSystemLibrary("wayland-egl");
                lib.linkSystemLibrary("xkbcommon");
            }
        }
    } else if (target.isWindows()) {
        lib.linkSystemLibrary("gdi32"); 
    }

    return lib;
}
