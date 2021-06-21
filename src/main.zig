const std = @import("std");
const VulkanContext = @import("vulkan_context.zig").VulkanContext;
const Window = @import("window.zig").Window;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var context = try VulkanContext.create(&gpa.allocator);
    defer context.destroy();
    std.log.info("Program completed!.", .{});
}
