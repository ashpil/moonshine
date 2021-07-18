const std = @import("std");
const VulkanContext = @import("./vulkan_context.zig");
const Window = @import("./window.zig").Window;
const Swapchain = @import("./swapchain.zig").Swapchain;
const RaytracingPipeline = @import("./pipeline.zig").RaytracingPipeline;
const Scene = @import("./scene.zig").Scene;

const commands = @import("./commands.zig");

const ComputeCommands = commands.ComputeCommands;
const RenderCommands = commands.RenderCommands;

const initial_width = 800;
const initial_height = 600;

var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
const allocator = &gpa.allocator;
var window: Window = undefined;
var context: VulkanContext = undefined;

pub fn main() !void {
    defer _ = gpa.deinit();

    window = try Window.create(initial_width, initial_height);
    defer window.destroy();

    context = try VulkanContext.create(allocator, window.handle);
    defer context.destroy();

    var swapchain = try Swapchain(&context, allocator).create(.{ .width = initial_width, .height = initial_height });
    defer swapchain.destroy();

    var transfer_commands = try ComputeCommands(&context).create(0);
    defer transfer_commands.destroy();
    
    var pipeline = try RaytracingPipeline(&context).create();
    defer pipeline.destroy();

    var render_commands = try RenderCommands(&context, allocator).create(&pipeline, swapchain.images.len, 0);
    defer render_commands.destroy();

    var scene = try Scene(&context, allocator).create(&transfer_commands);
    defer scene.destroy();

    std.log.info("Program completed!.", .{});
}
