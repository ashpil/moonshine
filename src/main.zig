const std = @import("std");
const VulkanContext = @import("./vulkan_context.zig").VulkanContext;
const Window = @import("./window.zig").Window;
const Swapchain = @import("./swapchain.zig").Swapchain;

const initial_width = 800;
const initial_height = 600;

pub fn main() !void {
    var window = try Window.create(initial_width, initial_height);
    defer window.destroy();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var context = try VulkanContext.create(&gpa.allocator, window.handle);
    defer context.destroy();

    var swapchain = try Swapchain.create(&context, &gpa.allocator, .{ .width = initial_width, .height = initial_height });
    defer swapchain.destroy(&context, &gpa.allocator);


    std.log.info("Program completed!.", .{});
}
