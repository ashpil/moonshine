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
    const glfw = createGlfwLib(b, glfw_dir, target, mode) catch unreachable;
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

// adapted from mach glfw
fn createGlfwLib(b: *std.build.Builder, comptime dir: []const u8, target: std.zig.CrossTarget, mode: std.builtin.Mode) !*std.build.LibExeObjStep {
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

        const windows_sources = [_][]const u8 {
            "win32_thread.c",
            "wgl_context.c",
            "win32_init.c",
            "win32_monitor.c",
            "win32_time.c",
            "win32_joystick.c",
            "win32_window.c",
        };

        inline for (general_sources) |source| {
            try sources.append(source_dir ++ source);
        }

        if (target.isLinux()) {
            // TODO: wayland
            inline for (linux_sources ++ x11_sources) |source| {
                try sources.append(source_dir ++ source);
            }
        } else if (target.isWindows()) {
            inline for (windows_sources) |source| {
                try sources.append(source_dir ++ source);
            }
        }
    }

    lib.addCSourceFiles(sources.items, &[_][]const u8{
        "-std=c99",
        "-D_DEFAULT_SOURCE",
        if (target.isLinux()) "-D_GLFW_X11" else "-D_GLFW_WIN32",
        "-pedantic",
        "-Wdeclaration-after-statement",
        "-Wall",
    });

    // link necessary deps
    lib.linkLibC();

    if (target.isLinux()) {
        lib.linkSystemLibrary("X11"); 
    } else if (target.isWindows()) {
        lib.linkSystemLibrary("gdi32"); 
    }

    return lib;
}
