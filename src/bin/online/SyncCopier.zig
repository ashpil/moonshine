// TODO: this should really be killed
//
// really stupid and inefficient way to get stuff from device-local buffers/images back to CPU
// should not be used for "real" transfers that benefit from efficiency
//
// more-so designed for ease-of-use for debugging and inspecting stuff that doesn't usually need to be inspected

const core = @import("engine").core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const vk_helpers = core.vk_helpers;

const std = @import("std");
const vk = @import("vulkan");

buffer: core.mem.DownloadBuffer(u8),

encoder: Encoder,
ready_fence: vk.Fence,

const Self = @This();

pub fn create(vc: *const VulkanContext, max_bytes: u32) !Self {
    const buffer = try core.mem.DownloadBuffer(u8).create(vc, max_bytes, "sync copier");

    var encoder = try Encoder.create(vc, "sync copier");
    errdefer encoder.destroy(vc);

    const ready_fence = try vc.device.createFence(&.{}, null);

    return Self {
        .buffer = buffer,

        .encoder = encoder,
        .ready_fence = ready_fence,
    };
}

pub fn copyBufferItem(self: *Self, vc: *const VulkanContext, comptime BufferInner: type, buffer: vk.Buffer, idx: vk.DeviceSize) !BufferInner {
    std.debug.assert(@sizeOf(BufferInner) <= self.buffer.len);

    try self.encoder.begin();
    self.encoder.copyBuffer(buffer, self.buffer.handle, &[_]vk.BufferCopy {
        .{
            .src_offset = @sizeOf(BufferInner) * idx,
            .dst_offset = 0,
            .size = @sizeOf(BufferInner),
        }
    });
    try self.encoder.submit(vc.queue, .{ .fence = self.ready_fence });

    _ = try vc.device.waitForFences(1, @ptrCast(&self.ready_fence), vk.TRUE, std.math.maxInt(u64));
    try vc.device.resetFences(1, @ptrCast(&self.ready_fence));
    try vc.device.resetCommandPool(self.encoder.pool, .{});

    return @as(*BufferInner, @ptrCast(@alignCast(self.buffer.mapped))).*;
}

pub fn copyImagePixel(self: *Self, vc: *const VulkanContext, comptime PixelType: type, src_image: vk.Image, src_layout: vk.ImageLayout, offset: vk.Offset3D) !PixelType {
    std.debug.assert(@sizeOf(PixelType) <= self.buffer.len);

    try self.encoder.begin();
    self.encoder.buffer.copyImageToBuffer(src_image, src_layout, self.buffer.handle, 1, @ptrCast(&vk.BufferImageCopy {
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
    try self.encoder.submit(vc.queue, .{ .fence = self.ready_fence });

    _ = try vc.device.waitForFences(1, @ptrCast(&self.ready_fence), vk.TRUE, std.math.maxInt(u64));
    try vc.device.resetFences(1, @ptrCast(&self.ready_fence));
    try vc.device.resetCommandPool(self.encoder.pool, .{});

    return @as(*PixelType, @ptrCast(@alignCast(self.buffer.mapped))).*;
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.buffer.destroy(vc);
    self.encoder.destroy(vc);
    vc.device.destroyFence(self.ready_fence, null);
}
