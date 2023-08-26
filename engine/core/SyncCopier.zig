// really stupid and inefficient way to get stuff from device-local buffers/images back to CPU
// should not be used for "real" transfers that benefit from require efficiency
//
// more-so designed for ease-of-use for debugging and inspecting stuff that doesn't usually need to be inspected

const core = @import("core.zig");
const VulkanContext = core.VulkanContext;
const VkAllocator = core.Allocator;
const Commands = core.Commands;
const vk_helpers = core.vk_helpers;

const std = @import("std");
const vk = @import("vulkan");

buffer: VkAllocator.HostBuffer(u8),

command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
ready_fence: vk.Fence,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, max_bytes: u32) !Self {
    const buffer = try vk_allocator.createHostBuffer(vc, u8, max_bytes, .{ .transfer_dst_bit = true });
    try vk_helpers.setDebugName(vc, buffer.handle, "sync copier");

    const command_pool = try vc.device.createCommandPool(&.{
        .queue_family_index = vc.physical_device.queue_family_index,
        .flags = .{ .transient_bit = true },
    }, null);
    errdefer vc.device.destroyCommandPool(command_pool, null);

    var command_buffer: vk.CommandBuffer = undefined;
    try vc.device.allocateCommandBuffers(&.{
        .level = vk.CommandBufferLevel.primary,
        .command_pool = command_pool,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer));

    const ready_fence = try vc.device.createFence(&.{}, null);

    return Self {
        .buffer = buffer,

        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .ready_fence = ready_fence,
    };
}

pub fn copyBufferItem(self: *Self, vc: *const VulkanContext, comptime BufferInner: type, buffer: VkAllocator.DeviceBuffer(BufferInner), idx: vk.DeviceSize) !BufferInner {
    std.debug.assert(@sizeOf(BufferInner) <= self.buffer.data.len);

    try vc.device.beginCommandBuffer(self.command_buffer, &.{});
    vc.device.cmdCopyBuffer(self.command_buffer, buffer.handle, self.buffer.handle, 1, vk_helpers.toPointerType(&vk.BufferCopy {
        .src_offset = @sizeOf(BufferInner) * idx,
        .dst_offset = 0,
        .size = @sizeOf(BufferInner),
    }));
    try vc.device.endCommandBuffer(self.command_buffer);

    try vc.device.queueSubmit2(vc.queue, 1, vk_helpers.toPointerType(&vk.SubmitInfo2 {
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = vk_helpers.toPointerType(&vk.CommandBufferSubmitInfo {
            .command_buffer = self.command_buffer,
            .device_mask = 0,
        }),
    }), self.ready_fence);
    _ = try vc.device.waitForFences(1, vk_helpers.toPointerType(&self.ready_fence), vk.TRUE, std.math.maxInt(u64));
    try vc.device.resetFences(1, vk_helpers.toPointerType(&self.ready_fence));
    try vc.device.resetCommandPool(self.command_pool, .{});

    return @as(*BufferInner, @ptrCast(@alignCast(self.buffer.data.ptr))).*;
}

pub fn copyImagePixel(self: *Self, vc: *const VulkanContext, comptime PixelType: type, src_image: vk.Image, src_layout: vk.ImageLayout, offset: vk.Offset3D) !PixelType {
    std.debug.assert(@sizeOf(PixelType) <= self.buffer.data.len);

    try vc.device.beginCommandBuffer(self.command_buffer, &.{});
    vc.device.cmdCopyImageToBuffer(self.command_buffer, src_image, src_layout, self.buffer.handle, 1, vk_helpers.toPointerType(&vk.BufferImageCopy {
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = vk.ImageSubresourceLayers {
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = offset,
        .image_extent = vk.Extent3D {
            .width = 1,
            .height = 1,
            .depth = 1,
        }
    }));
    try vc.device.endCommandBuffer(self.command_buffer);

    try vc.device.queueSubmit2(vc.queue, 1, vk_helpers.toPointerType(&vk.SubmitInfo2 {
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = vk_helpers.toPointerType(&vk.CommandBufferSubmitInfo{
            .command_buffer = self.command_buffer,
            .device_mask = 0,
        }),
    }), self.ready_fence);
    _ = try vc.device.waitForFences(1, vk_helpers.toPointerType(&self.ready_fence), vk.TRUE, std.math.maxInt(u64));
    try vc.device.resetFences(1, vk_helpers.toPointerType(&self.ready_fence));
    try vc.device.resetCommandPool(self.command_pool, .{});

    return @as(*PixelType, @ptrCast(@alignCast(self.buffer.data.ptr))).*;
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.buffer.destroy(vc);
    vc.device.destroyCommandPool(self.command_pool, null);
    vc.device.destroyFence(self.ready_fence, null);
}
