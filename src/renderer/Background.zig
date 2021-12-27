const std = @import("std");
const vk = @import("vulkan");

const Images = @import("./Images.zig");
const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const BackgroundDescriptorLayout = @import("./descriptor.zig").BackgroundDescriptorLayout;
const Commands = @import("./Commands.zig");

const utils = @import("./utils.zig");

image: Images,
descriptor_set: vk.DescriptorSet,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, comptime image_filepath: []const u8, descriptor_layout: *const BackgroundDescriptorLayout, sampler: vk.Sampler) !Self {

    const image = try Images.createTexture(vc, vk_allocator, allocator, &[_]Images.TextureSource {
        Images.TextureSource {
            .filepath = image_filepath,
        }
    }, commands);

    const descriptor_set = (try descriptor_layout.allocate_sets(vc, 1, [_]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = sampler,
                .image_view = image.data.items(.view)[0],
                .image_layout = .shader_read_only_optimal,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    }))[0];
    
    return Self {
        .image = image,
        .descriptor_set = descriptor_set,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.image.destroy(vc, allocator);
}
