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
        .descriptor_type = .sampled_image,
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

const Rgba2D = engine.fileformats.exr.helpers.Rgba2D;

images: ImageManager = .{},
data: std.ArrayListUnmanaged(struct {
    marginal: VkAllocator.DeviceBuffer(AliasTable.TableEntry),
    conditional: VkAllocator.DeviceBuffer(AliasTable.TableEntry),
    descriptor_set: vk.DescriptorSet,
}) = .{},
descriptor_layout: DescriptorLayout,

const Self = @This();

pub fn create(vc: *const VulkanContext) !Self {
    return Self {
        .descriptor_layout = try DescriptorLayout.create(vc, 1, .{}), // todo: pass in max sets from somewhere
    };
}

pub fn addDefaultBackground(self: Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands) !void {
    const image = Rgba2D {
        .ptr = .{
            .{ 1.0, 1.0, 1.0, 1.0 },
        },
        .extent = .{
            .width = 1,
            .height = 1,
        }
    };
    try self.addBackground(vc, vk_allocator, allocator, commands, image, "default");
}

fn luminance(rgb: [3]f32) f32 {
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}

// a lot of unnecessary copying if this ever needs to be optimized
pub fn addBackground(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, color_image: Rgba2D, name: []const u8) !void {
    const texture_name = try std.fmt.allocPrintZ(allocator, "background {s}", .{name});
    defer allocator.free(texture_name);
    try self.images.uploadTexture(vc, vk_allocator, allocator, commands, ImageManager.TextureSource {
        .raw = .{
            .bytes = std.mem.sliceAsBytes(color_image.asSlice()),
            .extent = color_image.extent,
            .format = .r32g32b32a32_sfloat,
        },
    }, texture_name);
    
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
            std.mem.copy(AliasTable.TableEntry, flat_entries[row_idx * color_image.extent.width..(row_idx + 1) * color_image.extent.width], table.entries);
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
            .descriptor_type = .sampled_image,
            .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                .sampler = .null_handle,
                .image_view = self.images.data.items(.view)[0],
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
        .descriptor_set = descriptor_set,
        .marginal = marginal,
        .conditional = conditional,
    });
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.images.destroy(vc, allocator);
    for (self.data.items) |data| {
        data.marginal.destroy(vc);
        data.conditional.destroy(vc);
    }
    self.data.deinit(allocator);
    self.descriptor_layout.destroy(vc);
}
