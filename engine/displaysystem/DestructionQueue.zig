const std = @import("std");
const vk = @import("vulkan");

const rendersystem = @import("../engine.zig").rendersystem;
const VulkanContext = rendersystem.VulkanContext;
const ImageManager = rendersystem.ImageManager;

// TODO: how to make this use some sort of duck typing and take in any 
// type with a `destroy` function
const Item = union(enum) {
    swapchain: vk.SwapchainKHR,
    image: ImageManager,

    fn destroy(self: *Item, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .swapchain => |swapchain| vc.device.destroySwapchainKHR(swapchain, null),
            .image => |*image| image.destroy(vc, allocator),
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

pub fn add(self: *Self, allocator: std.mem.Allocator, item: anytype) !void {
    if (@TypeOf(item) == ImageManager) {
        try self.queue.append(allocator, .{ .image = item });
    } else if (@TypeOf(item) == vk.SwapchainKHR) {
        try self.queue.append(allocator, .{ .swapchain = item });
    } else @compileError("Unknown destruction type: " ++ @typeName(@TypeOf(item)));
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    for (self.queue.items) |*item| item.destroy(vc, allocator);
    self.queue.deinit(allocator);
}
