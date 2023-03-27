const std = @import("std");
const vk = @import("vulkan");

const core = @import("./core.zig");
const VulkanContext = core.VulkanContext;
const DeviceBuffer = core.Allocator.DeviceBuffer;

// TODO: how to make this use some sort of duck typing and take in any 
// type with a `destroy` function
const Item = union(enum) {
    swapchain: vk.SwapchainKHR,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
    buffer: vk.Buffer,

    fn destroy(self: *Item, vc: *const VulkanContext) void {
        switch (self.*) {
            .swapchain => |swapchain| vc.device.destroySwapchainKHR(swapchain, null),
            .pipeline_layout => |pipeline_layout| vc.device.destroyPipelineLayout(pipeline_layout, null),
            .pipeline => |pipeline| vc.device.destroyPipeline(pipeline, null),
            .buffer => |buffer| vc.device.destroyBuffer(buffer, null),
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
    if (@TypeOf(item) == vk.SwapchainKHR) {
        try self.queue.append(allocator, .{ .swapchain = item });
    } else if (@TypeOf(item) == vk.PipelineLayout) {
        try self.queue.append(allocator, .{ .pipeline_layout = item });
    } else if (@TypeOf(item) == vk.Pipeline) {
        try self.queue.append(allocator, .{ .pipeline = item });
    } else if (@TypeOf(item) == vk.Buffer) {
        try self.queue.append(allocator, .{ .buffer = item });
    } else @compileError("Unknown destruction type: " ++ @typeName(@TypeOf(item)));
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    for (self.queue.items) |*item| item.destroy(vc);
    self.queue.deinit(allocator);
}
