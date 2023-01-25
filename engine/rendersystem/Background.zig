const std = @import("std");
const vk = @import("vulkan");

const ImageManager = @import("./ImageManager.zig");
const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const BackgroundDescriptorLayout = @import("./descriptor.zig").BackgroundDescriptorLayout;
const Commands = @import("./Commands.zig");
const AliasTable = @import("./alias_table.zig").NormalizedAliasTable;

const utils = @import("./utils.zig");
const asset = @import("../asset.zig");
const exr = @import("../fileformats/exr.zig");

images: ImageManager,
marginal: VkAllocator.DeviceBuffer,
conditional: VkAllocator.DeviceBuffer,
descriptor_set: vk.DescriptorSet,

const Self = @This();

// a lot of unnecessary copying if this ever needs to be optimized
pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, descriptor_layout: *const BackgroundDescriptorLayout, sampler: vk.Sampler, color_texture_path: []const u8) !Self {
    const color = blk: {
        const path = try asset.absoluteAssetPath(allocator, color_texture_path);
        defer allocator.free(path);

        const pathZ = try allocator.dupeZ(u8, path);
        defer allocator.free(pathZ);

        break :blk try exr.helpers.load(allocator, pathZ);
    };
    defer allocator.free(color.asSlice());

    const images = try ImageManager.createTexture(vc, vk_allocator, allocator, &[_]ImageManager.TextureSource {
        ImageManager.TextureSource {
            .raw = .{
                .bytes = std.mem.sliceAsBytes(color.asSlice()),
                .width = color.extent.width,
                .height = color.extent.height,
                .format = .r32g32b32a32_sfloat,
                .layout = .shader_read_only_optimal,
                .usage = .{ .sampled_bit = true },
            },
        },
    }, commands);

    const luminance = blk: {
        const buffer = try allocator.alloc(f32, color.extent.height * color.extent.width);
        for (color.asSlice()) |rgba, i| {
            const row_idx = i / color.extent.width;
            const sin_theta = std.math.sin(std.math.pi * (@intToFloat(f32, row_idx) + 0.5) / @intToFloat(f32, color.extent.height));
            buffer[i] = (rgba[0] * 0.2126 + rgba[1] * 0.7152 + rgba[2] * 0.0722) * sin_theta;
        }
        break :blk buffer;
    };
    defer allocator.free(luminance);

    const marginal_weights = try allocator.alloc(f32, color.extent.height);
    defer allocator.free(marginal_weights);

    const conditional = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(AliasTable.TableEntry) * color.extent.height * color.extent.width, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const flat_entries = try allocator.alloc(AliasTable.TableEntry, color.extent.height * color.extent.width);
        defer allocator.free(flat_entries);

        var row_idx: u32 = 0;
        while (row_idx < color.extent.height) : (row_idx += 1) {
            const row = luminance[row_idx * color.extent.width..(row_idx + 1) * color.extent.width];
            const table = try AliasTable.create(allocator, row);
            defer allocator.free(table.entries);
            marginal_weights[row_idx] = table.sum;
            std.mem.copy(AliasTable.TableEntry, flat_entries[row_idx * color.extent.width..(row_idx + 1) * color.extent.width], table.entries);
        }

        try commands.uploadData(vc, vk_allocator, buffer.handle, std.mem.sliceAsBytes(flat_entries));

        break :blk buffer;
    };
    errdefer conditional.destroy(vc);

    const marginal = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(AliasTable.TableEntry) * color.extent.height, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const table = try AliasTable.create(allocator, marginal_weights);
        defer allocator.free(table.entries);

        try commands.uploadData(vc, vk_allocator, buffer.handle, std.mem.sliceAsBytes(table.entries));

        break :blk buffer;
    };
    errdefer marginal.destroy(vc);

    const descriptor_set = (try descriptor_layout.allocate_sets(vc, 1, [_]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
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
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
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
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
                .buffer = conditional.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
    }))[0];
    
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
