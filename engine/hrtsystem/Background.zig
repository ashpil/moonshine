const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const VulkanContext = engine.core.VulkanContext;
const Commands = engine.core.Commands;
const VkAllocator = engine.core.Allocator;
const vk_helpers = engine.core.vk_helpers;
const ImageManager = engine.core.ImageManager;

const AliasTable = @import("./alias_table.zig").NormalizedAliasTable;

// must be kept in sync with shader
pub const DescriptorLayout = engine.core.descriptor.DescriptorLayout(&.{
    .{ // image
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
    .{ // marginal
        .binding = 1,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
    .{ // conditional
        .binding = 2,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
}, null, "Background");

const exr = engine.fileformats.exr;

images: ImageManager,
marginal: VkAllocator.DeviceBuffer(AliasTable.TableEntry),
conditional: VkAllocator.DeviceBuffer(AliasTable.TableEntry),
descriptor_set: vk.DescriptorSet,

const Self = @This();

// a lot of unnecessary copying if this ever needs to be optimized
pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, descriptor_layout: *const DescriptorLayout, sampler: vk.Sampler, color_texture_path: []const u8) !Self {
    const color = blk: {
        const pathZ = try allocator.dupeZ(u8, color_texture_path);
        defer allocator.free(pathZ);

        break :blk try exr.helpers.load(allocator, pathZ);
    };
    defer allocator.free(color.asSlice());

    const images = try ImageManager.createTexture(vc, vk_allocator, allocator, &[_]ImageManager.TextureSource {
        ImageManager.TextureSource {
            .raw = .{
                .bytes = std.mem.sliceAsBytes(color.asSlice()),
                .extent = color.extent,
                .format = .r32g32b32a32_sfloat,
                .layout = .shader_read_only_optimal,
                .usage = .{ .sampled_bit = true },
            },
        },
    }, commands);

    const luminance = blk: {
        const buffer = try allocator.alloc(f32, color.extent.height * color.extent.width);
        for (color.asSlice(), 0..) |rgba, i| {
            const row_idx = i / color.extent.width;
            const sin_theta = std.math.sin(std.math.pi * (@as(f32, @floatFromInt(row_idx)) + 0.5) / @as(f32, @floatFromInt(color.extent.height)));
            buffer[i] = (rgba[0] * 0.2126 + rgba[1] * 0.7152 + rgba[2] * 0.0722) * sin_theta;
        }
        break :blk buffer;
    };
    defer allocator.free(luminance);

    const marginal_weights = try allocator.alloc(f32, color.extent.height);
    defer allocator.free(marginal_weights);

    const conditional = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, AliasTable.TableEntry, color.extent.height * color.extent.width, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const flat_entries = try allocator.alloc(AliasTable.TableEntry, color.extent.height * color.extent.width);
        defer allocator.free(flat_entries);

        for (0..color.extent.height) |row_idx| {
            const row = luminance[row_idx * color.extent.width..(row_idx + 1) * color.extent.width];
            const table = try AliasTable.create(allocator, row);
            defer allocator.free(table.entries);
            marginal_weights[row_idx] = table.sum;
            std.mem.copy(AliasTable.TableEntry, flat_entries[row_idx * color.extent.width..(row_idx + 1) * color.extent.width], table.entries);
        }

        try commands.uploadData(AliasTable.TableEntry, vc, vk_allocator, buffer, flat_entries);

        break :blk buffer;
    };
    errdefer conditional.destroy(vc);

    const marginal = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, AliasTable.TableEntry, color.extent.height, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const table = try AliasTable.create(allocator, marginal_weights);
        defer allocator.free(table.entries);

        try commands.uploadData(AliasTable.TableEntry, vc, vk_allocator, buffer, table.entries);

        break :blk buffer;
    };
    errdefer marginal.destroy(vc);

    const descriptor_set = try descriptor_layout.allocate_set(vc, [_]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                .sampler = sampler,
                .image_view = images.data.items(.view)[0],
                .image_layout = .shader_read_only_optimal,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = marginal.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 2,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = conditional.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
    });
    
    return Self {
        .images = images,
        .descriptor_set = descriptor_set,
        .marginal = marginal,
        .conditional = conditional,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.images.destroy(vc, allocator);
    self.marginal.destroy(vc);
    self.conditional.destroy(vc);
}
