const vk = @import("vulkan");
const std = @import("std");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const VkAllocator = core.Allocator;
const Commands = core.Commands;
const dds = engine.fileformats.dds;

const vector = @import("../vector.zig");
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);

pub const ImageCreateRawInfo = struct {
    extent: vk.Extent2D,
    usage: vk.ImageUsageFlags,
    format: vk.Format,
};

pub const RawSource = struct {
    bytes: []const u8,
    extent: vk.Extent2D,
    format: vk.Format,
    layout: vk.ImageLayout,
    usage: vk.ImageUsageFlags,
};

pub const TextureSource = union(enum) {
    raw: RawSource,
    f32x3: F32x3,
    f32x2: F32x2,
    f32x1: f32,
};

const Data = std.MultiArrayList(Image);

data: Data,

const Self = @This();

pub fn createRaw(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, infos: []const ImageCreateRawInfo) !Self {
    var data = Data {};
    try data.ensureTotalCapacity(allocator, infos.len);
    errdefer data.deinit(allocator);

    for (infos) |info| {
        const image = try Image.create(vc, vk_allocator, info.extent, info.usage, info.format, false);

        data.appendAssumeCapacity(image);
    }

    return Self {
        .data = data,
    };
}

pub fn createTexture(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, sources: []const TextureSource, commands: *Commands) !Self {
    var data = Data {};
    try data.ensureTotalCapacity(allocator, sources.len);
    errdefer data.deinit(allocator);

    const extents = try allocator.alloc(vk.Extent2D, sources.len);
    defer allocator.free(extents);

    const bytes = try allocator.alloc([]const u8, sources.len);
    defer allocator.free(bytes);

    const is_cubemaps = try allocator.alloc(bool, sources.len);
    defer allocator.free(is_cubemaps);

    const dst_layouts = try allocator.alloc(vk.ImageLayout, sources.len);
    defer allocator.free(dst_layouts);

    var free_bytes = std.ArrayList([]const u8).init(allocator);
    defer free_bytes.deinit();
    defer for (free_bytes.items) |free_byte| allocator.free(free_byte);

    for (sources, extents, bytes, is_cubemaps, dst_layouts) |*source, *extent, *byte, *is_cubemap, *dst_layout| {
        const image = switch (source.*) {
            .raw => |raw_info| blk: {
                extent.* = raw_info.extent;
                is_cubemap.* = false;
                dst_layout.* = raw_info.layout;
                byte.* = raw_info.bytes;

                break :blk try Image.create(vc, vk_allocator, extent.*, raw_info.usage.merge(.{ .transfer_dst_bit = true }), raw_info.format, is_cubemap.*);
            },
            .f32x3 => blk: {
                byte.* = std.mem.asBytes(&source.f32x3);
                extent.* = vk.Extent2D {
                    .width = 1,
                    .height = 1,
                };
                is_cubemap.* = false;
                dst_layout.* = .shader_read_only_optimal;
                
                break :blk try Image.create(vc, vk_allocator, extent.*, .{ .transfer_dst_bit = true, .sampled_bit = true }, .r32g32b32a32_sfloat, false);
            },
            .f32x2 => blk: {
                byte.* = std.mem.asBytes(&source.f32x2);
                extent.* = vk.Extent2D {
                    .width = 1,
                    .height = 1,
                };
                is_cubemap.* = false;
                dst_layout.* = .shader_read_only_optimal;
                
                break :blk try Image.create(vc, vk_allocator, extent.*, .{ .transfer_dst_bit = true, .sampled_bit = true }, .r32g32_sfloat, false);
            },
            .f32x1 => blk: {
                byte.* = std.mem.asBytes(&source.f32x1);
                extent.* = vk.Extent2D {
                    .width = 1,
                    .height = 1,
                };
                is_cubemap.* = false;
                dst_layout.* = .shader_read_only_optimal;

                break :blk try Image.create(vc, vk_allocator, extent.*, .{ .transfer_dst_bit = true, .sampled_bit = true }, .r32_sfloat, false);
            },
        };
        data.appendAssumeCapacity(image);
    }

    const images = data.items(.handle);
    const sizes = data.items(.size_in_bytes);

    try commands.uploadDataToImages(vc, vk_allocator, allocator, images, bytes, sizes, extents, is_cubemaps, dst_layouts);

    return Self {
        .data = data,
    };      
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    const data_slice = self.data.slice();
    const views = data_slice.items(.view);
    const images = data_slice.items(.handle);
    const memories = data_slice.items(.memory);

    for (views, images, memories) |view, image, memory| {
        vc.device.destroyImageView(view, null);
        vc.device.destroyImage(image, null);
        vc.device.freeMemory(memory, null);
    }
    self.data.deinit(allocator);
}

pub fn createSampler(vc: *const VulkanContext) !vk.Sampler {
    return try vc.device.createSampler(&.{
        .flags = .{},
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .mipmap_mode = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
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
}

const Image = struct {

    handle: vk.Image,
    view: vk.ImageView,
    memory: vk.DeviceMemory,
    size_in_bytes: vk.DeviceSize,

    fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, size: vk.Extent2D, usage: vk.ImageUsageFlags, format: vk.Format, is_cubemap: bool) !Image {
        const extent = vk.Extent3D {
            .width = size.width,
            .height = size.height,
            .depth = 1,
        };

        const image_create_info = vk.ImageCreateInfo {
            .flags = if (is_cubemap) .{ .cube_compatible_bit = true } else .{},
            .image_type = if (extent.height == 1 and extent.width != 1) .@"1d" else .@"2d",
            .format = format,
            .extent = extent,
            .mip_levels = 1,
            .array_layers = if (is_cubemap) 6 else 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = usage,
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .initial_layout = .@"undefined",
        };

        const handle = try vc.device.createImage(&image_create_info, null);
        errdefer vc.device.destroyImage(handle, null);

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
            .view_type = if (is_cubemap) vk.ImageViewType.cube else if (extent.height == 1 and extent.width != 1) vk.ImageViewType.@"1d" else vk.ImageViewType.@"2d",
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
        };

        const view = try vc.device.createImageView(&view_create_info, null);
        errdefer vc.device.destroyImageView(view, null);

        return Image {
            .memory = memory,
            .handle = handle,
            .view = view,
            .size_in_bytes = mem_requirements.size,
        };
    }
};
