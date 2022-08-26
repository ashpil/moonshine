const std = @import("std");

const VulkanContext = @import("engine").rendersystem.VulkanContext;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var context = try VulkanContext.create(.{ .allocator = allocator, .app_name = "offline" });
    try context.device.deviceWaitIdle();
    context.destroy();

    std.log.info("Program completed!", .{});
}
