const std = @import("std");
const VulkanContext = @import("./vulkan_context.zig").VulkanContext;
const Window = @import("./window.zig").Window;
const Swapchain = @import("./swapchain.zig").Swapchain;
const MeshesFn = @import("./mesh.zig").Meshes;
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

    const TransferCommands = ComputeCommands(&context);
    var transfer_commands = try TransferCommands.create();
    defer transfer_commands.destroy();

    const compute_queue = context.device.getDeviceQueue(context.physical_device.queue_families.compute, 0);
    
    const Pipeline = RaytracingPipeline(&context);
    var pipeline = try Pipeline.create();
    defer pipeline.destroy();

    var render_commands = try RenderCommands(&context, allocator, Pipeline).create(&pipeline, swapchain.images.len);
    defer render_commands.destroy();

    const vertices_bytes = @bitCast([24]u8, vertices);
    const Meshes = MeshesFn(&context, allocator, TransferCommands);
    var meshes = try Meshes.createOne(&transfer_commands, compute_queue, &vertices_bytes);
    defer meshes.destroy();

    const BLASes = BottomLevelAccels(&context, allocator, Meshes, TransferCommands);
    var blases = try BLASes.create(&transfer_commands, compute_queue, meshes);
    defer blases.destroy();

    var tlas = try TopLevelAccel(&context, BLASes, TransferCommands).create(&transfer_commands, compute_queue, &blases);
    defer tlas.destroy();

    std.log.info("Program completed!.", .{});
}
