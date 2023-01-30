const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const ImageManager = @import("./ImageManager.zig");
const Commands = @import("./Commands.zig");
const DescriptorLayout = @import("./descriptor.zig").FilmDescriptorLayout;

const utils = @import("./utils.zig");

// 2 images -- first is display image, second is accumulation image
// accumulation is sum of all samples
// display is accumulation divided by sample_count
images: ImageManager,
descriptor_set: vk.DescriptorSet,
extent: vk.Extent2D,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, descriptor_layout: *const DescriptorLayout, extent: vk.Extent2D) !Self {
    var images = try ImageManager.createRaw(vc, vk_allocator, allocator, &.{
        .{
            .extent = extent,
            .usage = .{ .storage_bit = true, .transfer_src_bit = true, },
            .format = .r32g32b32a32_sfloat,
        },
        .{
            .extent = extent,
            .usage = .{ .storage_bit = true, },
            .format = .r32g32b32a32_sfloat,
        },
    });
    errdefer images.destroy(vc, allocator);

    const descriptor_set = try descriptor_layout.allocate_set(vc, [_]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = .null_handle,
                .image_view = images.data.items(.view)[0],
                .image_layout = .general,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = .null_handle,
                .image_view = images.data.items(.view)[1],
                .image_layout = .general,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    });

    return Self {
        .images = images,
        .descriptor_set = descriptor_set,
        .extent = extent,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.images.destroy(vc, allocator);
}
