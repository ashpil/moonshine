const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const VulkanContext = engine.core.VulkanContext;
const Commands = engine.core.Commands;
const VkAllocator = engine.core.Allocator;
const Image = engine.core.Image;

const AliasTable = @import("./alias_table.zig").NormalizedAliasTable;

// must be kept in sync with shader
pub const DescriptorLayout = engine.core.descriptor.DescriptorLayout(&.{
    .{ // image
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
    .{ // marginal
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
    .{ // conditional
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
}, .{}, 1, "Background");

const Rgba2D = engine.fileformats.exr.helpers.Rgba2D;

data: std.ArrayListUnmanaged(struct {
    marginal: VkAllocator.DeviceBuffer(AliasTable.TableEntry),
    conditional: VkAllocator.DeviceBuffer(AliasTable.TableEntry),
    image: Image,
    descriptor_set: vk.DescriptorSet,
}),
descriptor_layout: DescriptorLayout,
sampler: vk.Sampler,

const Self = @This();

pub fn create(vc: *const VulkanContext) !Self {
    const sampler = try vc.device.createSampler(&.{
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

    return Self {
        .descriptor_layout = try DescriptorLayout.create(vc, .{ sampler }),
        .data = .{},
        .sampler = sampler,
    };
}

pub fn addDefaultBackground(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands) !void {
    var color = [4]f32 { 1.0, 1.0, 1.0, 1.0 };
    const rgba = Rgba2D {
        .ptr = @ptrCast(&color),
        .extent = .{
            .width = 1,
            .height = 1,
        }
    };
    try self.addBackground(vc, vk_allocator, allocator, commands, rgba, "default");
}

fn luminance(rgb: [3]f32) f32 {
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}

// a lot of unnecessary copying if this ever needs to be optimized
pub fn addBackground(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, color_image: Rgba2D, name: []const u8) !void {
    const texture_name = try std.fmt.allocPrintZ(allocator, "background {s}", .{ name });
    defer allocator.free(texture_name);

    const image = try Image.create(vc, vk_allocator, color_image.extent, .{ .transfer_dst_bit = true, .sampled_bit = true }, .r32g32b32a32_sfloat, texture_name);
    errdefer image.destroy(vc);

    try commands.uploadDataToImage(vc, vk_allocator, image.handle, std.mem.sliceAsBytes(color_image.asSlice()), color_image.extent, .shader_read_only_optimal);

    // compute grayscale luminance image to use as our sampling weights
    const luminance_image = blk: {
        const buffer = try allocator.alloc(f32, color_image.extent.height * color_image.extent.width);
        for (color_image.asSlice(), 0..) |rgba, i| {
            const row_idx = i / color_image.extent.width;
            const sin_theta = std.math.sin(std.math.pi * (@as(f32, @floatFromInt(row_idx)) + 0.5) / @as(f32, @floatFromInt(color_image.extent.height)));
            buffer[i] = luminance(rgba[0..3].*) * sin_theta;
        }
        break :blk buffer;
    };
    defer allocator.free(luminance_image);

    // marginal weights to select a row
    const marginal_weights = try allocator.alloc(f32, color_image.extent.height);
    defer allocator.free(marginal_weights);

    // conditional weights to select within the column
    const conditional = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, AliasTable.TableEntry, color_image.extent.height * color_image.extent.width, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const flat_entries = try allocator.alloc(AliasTable.TableEntry, color_image.extent.height * color_image.extent.width);
        defer allocator.free(flat_entries);

        for (0..color_image.extent.height) |row_idx| {
            const row = luminance_image[row_idx * color_image.extent.width..(row_idx + 1) * color_image.extent.width];
            const table = try AliasTable.create(allocator, row);
            defer allocator.free(table.entries);
            marginal_weights[row_idx] = table.sum;
            @memcpy(flat_entries[row_idx * color_image.extent.width..(row_idx + 1) * color_image.extent.width], table.entries);
        }

        try commands.uploadData(AliasTable.TableEntry, vc, vk_allocator, buffer, flat_entries);

        break :blk buffer;
    };
    errdefer conditional.destroy(vc);

    const marginal = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, AliasTable.TableEntry, color_image.extent.height, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const table = try AliasTable.create(allocator, marginal_weights);
        defer allocator.free(table.entries);

        try commands.uploadData(AliasTable.TableEntry, vc, vk_allocator, buffer, table.entries);

        break :blk buffer;
    };
    errdefer marginal.destroy(vc);

    const descriptor_set = try self.descriptor_layout.allocate_set(vc, [_]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                .sampler = .null_handle,
                .image_view = image.view,
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

    try self.data.append(allocator, .{
        .image = image,
        .descriptor_set = descriptor_set,
        .marginal = marginal,
        .conditional = conditional,
    });
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    for (self.data.items) |data| {
        data.marginal.destroy(vc);
        data.conditional.destroy(vc);
        data.image.destroy(vc);
    }
    self.data.deinit(allocator);
    self.descriptor_layout.destroy(vc);
    vc.device.destroySampler(self.sampler, null);
}
