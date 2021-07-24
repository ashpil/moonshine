const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./vulkan_context.zig");
const Window = @import("./window.zig");
const Swapchain = @import("./swapchain.zig");
const RaytracingPipeline = @import("./pipeline.zig");
const Scene = @import("./scene.zig");
const DescriptorSet = @import("./descriptor_set.zig");
const Image = @import("./image.zig");
const commands = @import("./commands.zig");

const ComputeCommands = commands.ComputeCommands;
const RenderCommands = commands.RenderCommands;

const window_size = vk.Extent2D {
    .width = 800,
    .height = 600,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    var window = try Window.create(window_size);
    defer window.destroy();

    var context = try VulkanContext.create(allocator, window.handle);
    defer context.destroy();

    var swapchain = try Swapchain.create(&context, allocator, window_size);
    defer swapchain.destroy(&context, allocator);

    var transfer_commands = try ComputeCommands.create(&context, 0);
    defer transfer_commands.destroy(&context);

    var scene = try Scene.create(&context, allocator, &transfer_commands);
    defer scene.destroy(&context, allocator);

    var image = try Image.create(&context, window_size, .{ .storage_bit = true });
    defer image.destroy(&context);

    const image_info = vk.DescriptorImageInfo {
        .sampler = .null_handle,
        .image_view = image.view,
        .image_layout = vk.ImageLayout.general,
    };
    var sets = try DescriptorSet.create(&context, allocator, .{
        vk.ShaderStageFlags { .raygen_bit_khr = true },
        vk.ShaderStageFlags { .raygen_bit_khr = true },
    }, .{
        image_info,
        scene.tlas.handle,
    }, @intCast(u32, swapchain.images.len));
    defer sets.destroy(&context, allocator);
    
    var pipeline = try RaytracingPipeline.create(&context, &sets);
    defer pipeline.destroy(&context);

    var render_commands = try RenderCommands.create(&context, allocator, &pipeline, &sets, @intCast(u32, swapchain.images.len), 0);
    defer render_commands.destroy(&context, allocator);

    std.log.info("Program completed!.", .{});
}
