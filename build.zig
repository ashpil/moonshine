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
    exe.linkLibC();
    exe.linkSystemLibrary("glfw");

    // compile shaders
    const dir_cmd = b.addSystemCommand(&[_][]const u8 {
        "mkdir", "-p", "zig-cache/shaders"
    });

    exe.step.dependOn(&dir_cmd.step);
    exe.step.dependOn(&makeShaderStep(b, mode, "shader.rgen").step);
    exe.step.dependOn(&makeShaderStep(b, mode, "shader.rchit").step);
    exe.step.dependOn(&makeShaderStep(b, mode, "shader.rmiss").step);
    exe.step.dependOn(&makeShaderStep(b, mode, "shadow.rmiss").step);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

pub fn makeShaderStep(b: *std.build.Builder, mode: std.builtin.Mode, comptime shader_name: []const u8) *std.build.RunStep {
    return b.addSystemCommand(&[_][]const u8 {
        "glslc", "src/shaders/" ++ shader_name,
        "--target-env=vulkan1.2",
        "-o", "zig-cache/shaders/" ++ shader_name ++ ".spv",
        if (mode == .Debug) "-g" else "-O",
    });
}
