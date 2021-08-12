const vk = @import("vulkan");
const std = @import("std");

const VulkanContext = @import("./VulkanContext.zig");
const TransferCommands = @import("./commands.zig").ComputeCommands;

const utils = @import("./utils.zig");

handle: vk.Image,
view: vk.ImageView,
sampler: vk.Sampler,
memory: vk.DeviceMemory,

const Self = @This();

pub fn createCubeMap(vc: *const VulkanContext, commands: *TransferCommands, comptime texture_dir: []const u8, comptime size: comptime_int) !Self {
    var textures: [6]*const [size * size / 2]u8 = undefined;
    const names = .{
        "right.dds",
        "left.dds",
        "top.dds",
        "bottom.dds",
        "front.dds",
        "back.dds",
    };
    comptime for (names) |name, i| {
        textures[i] = @embedFile(texture_dir ++ name)[148..];
    };
    const extent = vk.Extent3D {
        .width = @intCast(u32, size),
        .height = @intCast(u32, size),
        .depth = 1,
    };
    const format = .bc1_rgb_srgb_block;  // this might need to be variable

    const handle = try vc.device.createImage(.{
        .flags = .{ .cube_compatible_bit = true },
        .image_type = .@"2d",
        .format = format,
        .extent = extent,
        .mip_levels = 1,
        .array_layers = 6,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .sampled_bit = true, .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .@"undefined",
    }, null);
    errdefer vc.device.destroyImage(handle, null);

    const mem_requirements = vc.device.getImageMemoryRequirements(handle);

    const memory = try vc.device.allocateMemory(.{
        .allocation_size = mem_requirements.size,
        .memory_type_index = try utils.findMemoryType(vc, mem_requirements.memory_type_bits, .{ .device_local_bit = true }),
    }, null);
    errdefer vc.device.freeMemory(memory, null);

    try vc.device.bindImageMemory(handle, memory, 0);

    const view = try vc.device.createImageView(.{
        .flags = .{},
        .image = handle,
        .view_type = .cube,
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
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
    }, null);
    errdefer vc.device.destroyImageView(view, null);

    const sampler = try vc.device.createSampler(.{
        .flags = .{},
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0.0,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 0.0,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .min_lod = 0.0,
        .max_lod = 0.0,
        .border_color = .float_opaque_white,
        .unnormalized_coordinates = vk.FALSE,
    }, null);

    try commands.transitionImageLayout(vc, handle, .@"undefined", .transfer_dst_optimal);

    var staging_buffer: vk.Buffer = undefined;
    var staging_buffer_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, mem_requirements.size, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &staging_buffer, &staging_buffer_memory);
    defer vc.device.destroyBuffer(staging_buffer, null);
    defer vc.device.freeMemory(staging_buffer_memory, null);

    const dst = @ptrCast([*]u8, (try vc.device.mapMemory(staging_buffer_memory, 0, mem_requirements.size, .{})).?);
    const layer_size = mem_requirements.size / 6;
    inline for (names) |_, i| {
        std.mem.copy(u8, dst[layer_size * i..layer_size * (i + 1)], textures[i]);
    }
    vc.device.unmapMemory(staging_buffer_memory);
    try commands.copyBufferToImage(vc, staging_buffer, handle, size, size, 6);
    try commands.transitionImageLayout(vc, handle, .@"undefined", .shader_read_only_optimal);

    return Self {
        .memory = memory,
        .handle = handle,
        .view = view,
        .sampler = sampler,
    };
}

pub fn destroy(self: *const Self, vc: *const VulkanContext) void {
    vc.device.destroySampler(self.sampler, null);
    vc.device.destroyImageView(self.view, null);
    vc.device.destroyImage(self.handle, null);
    vc.device.freeMemory(self.memory, null);
}