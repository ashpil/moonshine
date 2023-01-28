const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const ImageManager = @import("./ImageManager.zig");
const Swapchain = @import("./Swapchain.zig");

// TODO: how to make this use some sort of duck typing and take in any 
// type with a `destroy` function
const Item = union(enum) {
    swapchain: Swapchain,
    image: ImageManager,

    fn destroy(self: *Item, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .swapchain => |swapchain| swapchain.destroy(vc),
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
    } else if (@TypeOf(item) == Swapchain) {
        try self.queue.append(allocator, .{ .swapchain = item });
    } else @compileError("Unknown destruction type: " ++ @typeName(@TypeOf(item)));
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    for (self.queue.items) |*item| item.destroy(vc, allocator);
    self.queue.deinit(allocator);
}
