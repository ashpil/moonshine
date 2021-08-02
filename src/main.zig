const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./vulkan_context.zig");
const Window = @import("./window.zig");
const Swapchain = @import("./swapchain.zig");
const RaytracingPipeline = @import("./pipeline.zig");
const Scene = @import("./scene.zig");
const Descriptor = @import("./descriptor.zig").Descriptor;
const Image = @import("./image.zig");
const Display = @import("./display.zig").Display;
const commands = @import("./commands.zig");

const ComputeCommands = commands.ComputeCommands;
const RenderCommands = commands.RenderCommand;

const initial_window_size = vk.Extent2D {
    .width = 800,
    .height = 600,
};

const frame_count = 2;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    var window = try Window.create(initial_window_size);
    defer window.destroy();

    var context = try VulkanContext.create(allocator, &window);
    defer context.destroy();

    var display = try Display(frame_count).create(&context, allocator, initial_window_size);
    defer display.destroy(&context, allocator);

    var transfer_commands = try ComputeCommands.create(&context);
    defer transfer_commands.destroy(&context);

    var scene = try Scene.create(&context, allocator, &transfer_commands);
    defer scene.destroy(&context, allocator);

    const image_info = vk.DescriptorImageInfo {
        .sampler = .null_handle,
        .image_view = display.storage_image.view,
        .image_layout = vk.ImageLayout.general,
    };
    var sets = try Descriptor(frame_count).create(&context, .{
        vk.ShaderStageFlags { .raygen_bit_khr = true },
        vk.ShaderStageFlags { .raygen_bit_khr = true },
    }, .{
        image_info,
        scene.tlas.handle,
    });
    defer sets.destroy(&context);

    var pipeline = try RaytracingPipeline.create(&context, allocator, &transfer_commands, sets.layout);
    defer pipeline.destroy(&context);

    while (!window.shouldClose()) {
        window.pollEvents();
        const buffer = try display.startFrame(&context);
        try RenderCommands(frame_count).record(&context, buffer, &pipeline, &display, &sets.sets);
        try display.endFrame(&context);
    }

    try context.device.deviceWaitIdle();

    std.log.info("Program completed!.", .{});
}
