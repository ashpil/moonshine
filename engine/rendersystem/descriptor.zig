const std = @import("std");
const vk = @import("vulkan");
const VulkanContext = @import("./VulkanContext.zig");

pub const InputDescriptorLayout = DescriptorLayout(&.{
    .{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
});

pub const OutputDescriptorLayout = DescriptorLayout(&.{
    .{
        .binding = 0,
        .descriptor_type = .storage_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 1,
        .descriptor_type = .storage_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
});

pub const BackgroundDescriptorLayout = DescriptorLayout(&.{
    .{
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 1,
        .descriptor_type = .storage_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 2,
        .descriptor_type = .storage_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 3,
        .descriptor_type = .storage_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 4,
        .descriptor_type = .storage_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
});

const max_textures = 4; // TODO: think about this more
pub const SceneDescriptorLayout = DescriptorLayout(&.{
    .{
        .binding = 0,
        .descriptor_type = .acceleration_structure_khr,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 1,
        .descriptor_type = .sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true, .closest_hit_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 2,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 3,
        .descriptor_type = .sampled_image,
        .descriptor_count = max_textures,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 4,
        .descriptor_type = .sampled_image,
        .descriptor_count = max_textures,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 5,
        .descriptor_type = .sampled_image,
        .descriptor_count = max_textures,
        .stage_flags = .{ .closest_hit_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 6,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .closest_hit_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{
        .binding = 7,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .closest_hit_bit_khr = true },
        .p_immutable_samplers = null,
    },
});

pub fn DescriptorLayout(comptime bindings: []const vk.DescriptorSetLayoutBinding) type {
    return struct {
        handle: vk.DescriptorSetLayout,
        pool: vk.DescriptorPool,

        const Self = @This();

        pub fn create(vc: *const VulkanContext, comptime max_sets: comptime_int, binding_flags: ?[bindings.len]vk.DescriptorBindingFlags) !Self {
            
            const binding_flags_create_info = if (binding_flags) |flags| (&vk.DescriptorSetLayoutBindingFlagsCreateInfo {
                .binding_count = bindings.len,
                .p_binding_flags = &flags,
            }) else null;
            const create_info = vk.DescriptorSetLayoutCreateInfo {
                .flags = .{},
                .binding_count = bindings.len,
                .p_bindings = bindings.ptr,
                .p_next = binding_flags_create_info,
            };
            const handle = try vc.device.createDescriptorSetLayout(&create_info, null);
            errdefer vc.device.destroyDescriptorSetLayout(handle, null);

            comptime var pool_sizes: [bindings.len]vk.DescriptorPoolSize = undefined;
            comptime for (pool_sizes) |*pool_size, i| {
                pool_size.* = .{
                    .@"type" =  bindings[i].descriptor_type,
                    .descriptor_count = bindings[i].descriptor_count * max_sets,
                };
            };

            const pool = try vc.device.createDescriptorPool(&.{
                .flags = .{},
                .max_sets = max_sets,
                .pool_size_count = pool_sizes.len,
                .p_pool_sizes = &pool_sizes,
            }, null);
            errdefer vc.device.destroyDescriptorPool(pool, null);

            return Self {
                .handle = handle,
                .pool = pool,
            };
        }

        pub fn allocate_sets(self: *const Self, vc: *const VulkanContext, comptime duplicate_set_count: comptime_int, writes: [bindings.len]vk.WriteDescriptorSet) ![duplicate_set_count]vk.DescriptorSet {
            var descriptor_set_layouts: [duplicate_set_count]vk.DescriptorSetLayout = undefined;

            comptime var i = 0;
            inline while (i < duplicate_set_count) : (i += 1) {
                descriptor_set_layouts[i] = self.handle;
            }

            var descriptor_sets: [duplicate_set_count]vk.DescriptorSet = undefined;

            try vc.device.allocateDescriptorSets(&.{
                .descriptor_pool = self.pool,
                .descriptor_set_count = descriptor_sets.len,
                .p_set_layouts = &descriptor_set_layouts,
            }, &descriptor_sets);

            var descriptor_writes: [duplicate_set_count * bindings.len]vk.WriteDescriptorSet = undefined;

            comptime var j = 0;
            inline while (j < duplicate_set_count) : (j += 1) {
                comptime var k = 0;
                inline while (k < bindings.len) : (k += 1) {
                    descriptor_writes[j * duplicate_set_count + k] = writes[k];
                    descriptor_writes[j * duplicate_set_count + k].dst_set = descriptor_sets[j];
                }
            }

            vc.device.updateDescriptorSets(descriptor_writes.len, &descriptor_writes, 0, undefined);

            return descriptor_sets;
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            vc.device.destroyDescriptorPool(self.pool, null);
            vc.device.destroyDescriptorSetLayout(self.handle, null);
        }
    };
}