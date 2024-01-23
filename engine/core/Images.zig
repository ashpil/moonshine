const vk = @import("vulkan");
const std = @import("std");

const engine = @import("../engine.zig");
const core = engine.core;
const vk_helpers = engine.core.vk_helpers;
const VulkanContext = core.VulkanContext;
const VkAllocator = core.Allocator;
const Commands = core.Commands;

const F32x4 = engine.vector.Vec4(f32);
const F32x3 = engine.vector.Vec3(f32);
const F32x2 = engine.vector.Vec2(f32);

// TODO: image destruction

pub const TextureManager = struct {
    const max_descriptors = 1024; // TODO: consider using VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT
    // must be kept in sync with shader
    pub const DescriptorLayout = core.descriptor.DescriptorLayout(&.{
        .{
            .binding = 0,
            .descriptor_type = .sampled_image,
            .descriptor_count = max_descriptors,
            .stage_flags = .{ .raygen_bit_khr = true },
        }
    }, .{ .{ .partially_bound_bit = true, .update_unused_while_pending_bit = true } }, "Textures");

    pub const Source = union(enum) {
        pub const Raw = struct {
            bytes: []const u8,
            extent: vk.Extent2D,
            format: vk.Format,
        };

        raw: Raw,
        f32x3: F32x3,
        f32x2: F32x2,
        f32x1: f32,
    };

    comptime {
        // so that we can do some hacky stuff below like
        // reinterpret the f32x3 field as F32x4
        // TODO: even this is not quite right
        std.debug.assert(@sizeOf(Source) >= @sizeOf(F32x4));
    }

    data: std.MultiArrayList(Image),
    descriptor_layout: DescriptorLayout,
    descriptor_set: vk.DescriptorSet,

    pub fn create(vc: *const VulkanContext) !TextureManager {
        const descriptor_layout = try DescriptorLayout.create(vc, 1, .{});
        const descriptor_set = try descriptor_layout.allocate_set(vc, .{
            vk.WriteDescriptorSet {
                .dst_set = undefined,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 0,
                .descriptor_type = .sampled_image,
                .p_image_info = undefined,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            }
        });
        try vk_helpers.setDebugName(vc, descriptor_set, "textures");
        return TextureManager {
            .data = .{},
            .descriptor_layout = descriptor_layout,
            .descriptor_set = descriptor_set,
        };
    }

    pub const Handle = u32;

    pub fn uploadTexture(self: *TextureManager, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, source: Source, name: [:0]const u8) !Handle {
        const texture_index: Handle = @intCast(self.data.len);
        std.debug.assert(texture_index < max_descriptors);

        var extent: vk.Extent2D = undefined;
        var bytes: []const u8 = undefined;
        var format: vk.Format = undefined;
        switch (source) {
            .raw => |raw_info| {
                bytes = raw_info.bytes;
                extent = raw_info.extent;
                format = raw_info.format;
            },
            .f32x3 => {
                bytes = std.mem.asBytes(&source.f32x3);
                bytes.len = @sizeOf(F32x4); // we store this as f32x4
                extent = vk.Extent2D {
                    .width = 1,
                    .height = 1,
                };
                format = .r32g32b32a32_sfloat;
            },
            .f32x2 => {
                bytes = std.mem.asBytes(&source.f32x2);
                extent = vk.Extent2D {
                    .width = 1,
                    .height = 1,
                };
                format = .r32g32_sfloat;
            },
            .f32x1 => {
                bytes = std.mem.asBytes(&source.f32x1);
                extent = vk.Extent2D {
                    .width = 1,
                    .height = 1,
                };
                format = .r32_sfloat;
            },
        }
        const image = try Image.create(vc, vk_allocator, extent, .{ .transfer_dst_bit = true, .sampled_bit = true }, format, name);
        try self.data.append(allocator, image);

        try commands.uploadDataToImage(vc, vk_allocator, image.handle, bytes, extent, .shader_read_only_optimal);

        vc.device.updateDescriptorSets(1, @ptrCast(&.{
            vk.WriteDescriptorSet {
                .dst_set = self.descriptor_set,
                .dst_binding = 0,
                .dst_array_element = texture_index,
                .descriptor_count = 1,
                .descriptor_type = .sampled_image,
                .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                    .image_layout = .shader_read_only_optimal,
                    .image_view = image.view,
                    .sampler = .null_handle,
                }),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
        }), 0, null);

        return texture_index;
    }

    pub fn destroy(self: *TextureManager, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
        for (0..self.data.len) |i| {
            const image = self.data.get(i);
            image.destroy(vc);
        }
        self.data.deinit(allocator);
        self.descriptor_layout.destroy(vc);
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
};

pub const StorageImageManager = struct {
    data: std.MultiArrayList(Image) = .{},

    pub const Handle = u32;
    pub fn appendStorageImage(self: *StorageImageManager, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, extent: vk.Extent2D, usage: vk.ImageUsageFlags, format: vk.Format, name: [:0]const u8) !Handle {
        const image = try Image.create(vc, vk_allocator, extent, usage, format, name);
        try self.data.append(allocator, image);

        return @intCast(self.data.len - 1);
    }

    pub fn destroy(self: *StorageImageManager, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
        for (0..self.data.len) |i| {
            const image = self.data.get(i);
            image.destroy(vc);
        }
        self.data.deinit(allocator);
    }
};

pub const Image = struct {
    handle: vk.Image,
    view: vk.ImageView,
    memory: vk.DeviceMemory,

    pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, size: vk.Extent2D, usage: vk.ImageUsageFlags, format: vk.Format, name: [:0]const u8) !Image {
        const extent = vk.Extent3D {
            .width = size.width,
            .height = size.height,
            .depth = 1,
        };

        const image_create_info = vk.ImageCreateInfo {
            .image_type = if (extent.height == 1 and extent.width != 1) .@"1d" else .@"2d",
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
        };
    }

    pub fn destroy(self: Image, vc: *const VulkanContext) void {
        vc.device.destroyImageView(self.view, null);
        vc.device.destroyImage(self.handle, null);
        vc.device.freeMemory(self.memory, null);
    }
};
