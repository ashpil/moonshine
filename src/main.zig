const std = @import("std");
const VulkanContext = @import("./vulkan_context.zig");
const Window = @import("./window.zig").Window;
const Swapchain = @import("./swapchain.zig").Swapchain;
const Meshes = @import("./mesh.zig").Meshes;
const RaytracingPipeline = @import("./pipeline.zig").RaytracingPipeline;
const BottomLevelAccels = @import("./acceleration_structure.zig").BottomLevelAccels;
const TopLevelAccel = @import("./acceleration_structure.zig").TopLevelAccel;

const commands = @import("./commands.zig");

const ComputeCommands = commands.ComputeCommands;
const RenderCommands = commands.RenderCommands;

const initial_width = 800;
const initial_height = 600;

const vertices = [_]f32 {
    0.0, -0.5,
    0.5, 0.5,
    -0.5, 0.5,
};

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

    const vertices_bytes = @bitCast([24]u8, vertices);
    var meshes = try Meshes(&context, allocator).createOne(&transfer_commands, &vertices_bytes);
    defer meshes.destroy();

    var blases = try BottomLevelAccels(&context, allocator).create(&transfer_commands, meshes);
    defer blases.destroy();

    var tlas = try TopLevelAccel(&context, allocator).create(&transfer_commands, &blases);
    defer tlas.destroy();

    std.log.info("Program completed!.", .{});
}
