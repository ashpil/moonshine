const std = @import("std");
const vk = @import("vulkan");

const ImageManager = @import("./ImageManager.zig");
const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const BackgroundDescriptorLayout = @import("./descriptor.zig").BackgroundDescriptorLayout;
const Commands = @import("./Commands.zig");

const utils = @import("./utils.zig");

images: ImageManager,
descriptor_set: vk.DescriptorSet,

const Self = @This();

// currently uses this custom weird format -- probably best to migrate to something else at some point
pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, texture_dir: []const u8, descriptor_layout: *const BackgroundDescriptorLayout, sampler: vk.Sampler) !Self {
    const path1 = try std.fs.path.join(allocator, &.{ texture_dir, "color.dds" });
    defer allocator.free(path1);

    const path2 = try std.fs.path.join(allocator, &.{ texture_dir, "conditional_pdfs_integrals.raw" });
    defer allocator.free(path2);

    const path3 = try std.fs.path.join(allocator, &.{ texture_dir, "conditional_cdfs.raw" });
    defer allocator.free(path3);

    const path4 = try std.fs.path.join(allocator, &.{ texture_dir, "marginal_pdf_integral.raw" });
    defer allocator.free(path4);

    const path5 = try std.fs.path.join(allocator, &.{ texture_dir, "marginal_cdf.raw" });
    defer allocator.free(path5);

    const images = try ImageManager.createTexture(vc, vk_allocator, allocator, &[_]ImageManager.TextureSource {
        ImageManager.TextureSource {
            .dds_filepath = path1,
        },
        ImageManager.TextureSource {
            .raw_file = .{
                .filepath = path2,
                .width = 257,
                .height = 128,
                .format = .r32_sfloat,
                .usage = .{ .storage_bit = true },
            },
        },
        ImageManager.TextureSource {
            .raw_file = .{
                .filepath = path3,
                .width = 257,
                .height = 128,
                .format = .r32_sfloat,
                .usage = .{ .storage_bit = true },
            },
        },
        ImageManager.TextureSource {
            .raw_file = .{
                .filepath = path4,
                .width = 129,
                .height = 1,
                .format = .r32_sfloat,
                .usage = .{ .storage_bit = true },
            },
        },
        ImageManager.TextureSource {
            .raw_file = .{
                .filepath = path5,
                .width = 129,
                .height = 1,
                .format = .r32_sfloat,
                .usage = .{ .storage_bit = true },
            },
        },
    }, commands);

    const views = images.data.items(.view);

    const descriptor_set = (try descriptor_layout.allocate_sets(vc, 1, [_]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = sampler,
                .image_view = views[0],
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
            .descriptor_type = .storage_image,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = undefined,
                .image_view = views[1],
                .image_layout = .general,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 2,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = undefined,
                .image_view = views[2],
                .image_layout = .general,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 3,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = undefined,
                .image_view = views[3],
                .image_layout = .general,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 4,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = undefined,
                .image_view = views[4],
                .image_layout = .general,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    }))[0];
    
    return Self {
        .images = images,
        .descriptor_set = descriptor_set,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.images.destroy(vc, allocator);
}
