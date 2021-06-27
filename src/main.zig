const std = @import("std");
const VulkanContext = @import("./vulkan_context.zig").VulkanContext;
const Window = @import("./window.zig").Window;
const Swapchain = @import("./swapchain.zig").Swapchain;
const Model = @import("./model.zig").Model;
const Commands = @import("./commands.zig").Commands;
const Pipeline = @import("./pipeline.zig").RaytracingPipeline;

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
    defer swapchain.destroy(&context, &gpa.allocator);

    var commands = try Commands.create(&context);
    defer commands.destroy(&context);

    const vertices_bytes = @bitCast([24]u8, vertices);
    var model = try Model.create(&context, &commands, &vertices_bytes);
    defer model.destroy(&context);

    var pipeline = try Pipeline.create(&context);
    defer pipeline.destroy(&context);

    std.log.info("Program completed!.", .{});
}
