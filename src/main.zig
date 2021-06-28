const std = @import("std");
const VulkanContext = @import("./vulkan_context.zig").VulkanContext;
const Window = @import("./window.zig").Window;
const Swapchain = @import("./swapchain.zig").Swapchain;
const Model = @import("./model.zig").Model;
const Pipeline = @import("./pipeline.zig").RaytracingPipeline;

const commands = @import("./commands.zig");

const TransferCommands = commands.TransferCommands;
const RenderCommands = commands.RenderCommands;

const initial_width = 800;
const initial_height = 600;

const vertices = [_]f32 {
    0.0, -0.5,
    0.5, 0.5,
    -0.5, 0.5,
};

pub fn main() !void {
    var window = try Window.create(initial_width, initial_height);
    defer window.destroy();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var context = try VulkanContext.create(&gpa.allocator, window.handle);
    defer context.destroy();

    var swapchain = try Swapchain.create(&context, &gpa.allocator, .{ .width = initial_width, .height = initial_height });
    defer swapchain.destroy(&context);

    var transfer_commands = try TransferCommands.create(&context);
    defer transfer_commands.destroy(&context);

    const compute_queue = context.device.getDeviceQueue(context.physical_device.queue_families.compute, 0);
    
    var pipeline = try Pipeline.create(&context);
    defer pipeline.destroy(&context);

    var render_commands = try RenderCommands.create(&context, &gpa.allocator, &pipeline, swapchain.images.len);
    defer render_commands.destroy(&context);

    const vertices_bytes = @bitCast([24]u8, vertices);
    var model = try Model.create(&context, &transfer_commands, compute_queue, &vertices_bytes);
    defer model.destroy(&context);

    std.log.info("Program completed!.", .{});
}
