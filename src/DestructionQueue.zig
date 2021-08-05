const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const Image = @import("./Image.zig");

const Item = union(enum) {
    swapchain: vk.SwapchainKHR,
    image: Image,

    fn destroy(self: Item, vc: *const VulkanContext) void {
        switch (self) {
            .swapchain => |swapchain| vc.device.destroySwapchainKHR(swapchain, null),
            .image => |image| image.destroy(vc),
        }
    }
};

const Queue = std.ArrayListUnmanaged(Item);

queue: Queue,

const Self = @This();

pub fn create() Self {
    return Self {
        .queue = Queue {},
    };
}

pub fn add(self: *Self, allocator: *std.mem.Allocator, item: anytype) !void {
    if (@TypeOf(item) == Image) {
        try self.queue.append(allocator, .{ .image = item });
    } else if (@TypeOf(item) == vk.SwapchainKHR) {
        try self.queue.append(allocator, .{ .swapchain = item });
    } else unreachable;
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator) void {
    for (self.queue.items) |item| item.destroy(vc);
    self.queue.deinit(allocator);
}
