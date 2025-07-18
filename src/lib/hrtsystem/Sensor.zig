const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const VulkanContext =  engine.core.VulkanContext;
const Encoder =  engine.core.Encoder;
const Image = engine.core.Image;

image: Image,
extent: vk.Extent2D,
sample_count: u32,

const Self = @This();

pub fn create(vc: *const VulkanContext, extent: vk.Extent2D, name: [:0]const u8) !Self {
    const image = try Image.create(vc, extent, .{ .storage_bit = true, .sampled_bit = true, .transfer_src_bit = true, }, .r32g32b32a32_sfloat, false, name);
    errdefer image.destroy(vc);

    return Self {
        .image = image,
        .extent = extent,
        .sample_count = 0,
    };
}

pub fn aspectRatio(self: Self) f32 {
    return @as(f32, @floatFromInt(self.extent.width)) / @as(f32, @floatFromInt(self.extent.height));
}

pub fn clear(self: *Self) void {
    self.sample_count = 0;
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.image.destroy(vc);
}
