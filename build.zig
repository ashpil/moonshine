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
