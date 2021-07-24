const vk = @import("vulkan");

const VulkanContext = @import("./vulkan_context.zig");

const utils = @import("./utils.zig");

handle: vk.Image,
view: vk.ImageView,
memory: vk.DeviceMemory,

const Self = @This();

pub fn create(vc: *const VulkanContext, size: vk.Extent2D, usage: vk.ImageUsageFlags) !Self {
    const extent = vk.Extent3D {
        .width = size.width,
        .height = size.height,
        .depth = 1,
    };
    const format = .r32g32b32a32_sfloat;  // this might need to be variable

    const handle = try vc.device.createImage(.{
        .flags = .{},
        .image_type = .@"2d",
        .format = format,
        .extent = extent,
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .@"undefined",
    }, null);

    const mem_requirements = vc.device.getImageMemoryRequirements(handle);

    const memory = try vc.device.allocateMemory(.{
        .allocation_size = mem_requirements.size,
        .memory_type_index = try utils.findMemoryType(vc, mem_requirements.memory_type_bits, .{ .device_local_bit = true }),
    }, null);

    try vc.device.bindImageMemory(handle, memory, 0);

    const view = try vc.device.createImageView(.{
        .flags = .{},
        .image = handle,
        .view_type = .@"2d",
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
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);

    return Self {
        .memory = memory,
        .handle = handle,
        .view = view,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    vc.device.destroyImageView(self.view, null);
    vc.device.destroyImage(self.handle, null);
    vc.device.freeMemory(self.memory, null);
}