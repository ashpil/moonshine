const vk = @import("vulkan");
const std = @import("std");

const engine = @import("../engine.zig");
const core = engine.core;
const vk_helpers = core.vk_helpers;
const VulkanContext = core.VulkanContext;
const VkAllocator = core.Allocator;

const Self = @This();
 
handle: vk.Image,
view: vk.ImageView,
memory: vk.DeviceMemory,

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, size: vk.Extent2D, usage: vk.ImageUsageFlags, format: vk.Format, with_mips: bool, name: [:0]const u8) !Self {
    const extent = vk.Extent3D {
        .width = size.width,
        .height = size.height,
        .depth = 1,
    };

    const image_create_info = vk.ImageCreateInfo {
        .image_type = if (extent.height == 1 and extent.width != 1) .@"1d" else .@"2d",
        .format = format,
        .extent = extent,
        .mip_levels = if (with_mips) std.math.log2(@max(extent.width, extent.height, extent.depth)) + 1 else 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .undefined,
    };

    const handle = try vc.device.createImage(&image_create_info, null);
    errdefer vc.device.destroyImage(handle, null);
    if (name.len != 0) try vk_helpers.setDebugName(vc, handle, name);

    const mem_requirements = vc.device.getImageMemoryRequirements(handle);

    const memory = try vc.device.allocateMemory(&.{
        .allocation_size = mem_requirements.size,
        .memory_type_index = try vk_allocator.findMemoryType(mem_requirements.memory_type_bits, .{ .device_local_bit = true }),
    }, null);
    errdefer vc.device.freeMemory(memory, null);

    try vc.device.bindImageMemory(handle, memory, 0);

    const view_create_info = vk.ImageViewCreateInfo {
        .flags = .{},
        .image = handle,
        .view_type = if (extent.height == 1 and extent.width != 1) vk.ImageViewType.@"1d" else vk.ImageViewType.@"2d",
        .format = format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
    };

    const view = try vc.device.createImageView(&view_create_info, null);
    errdefer vc.device.destroyImageView(view, null);

    return Self {
        .memory = memory,
        .handle = handle,
        .view = view,
    };
}

pub fn destroy(self: Self, vc: *const VulkanContext) void {
    vc.device.destroyImageView(self.view, null);
    vc.device.destroyImage(self.handle, null);
    vc.device.freeMemory(self.memory, null);
}
