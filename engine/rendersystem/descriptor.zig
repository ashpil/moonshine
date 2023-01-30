const std = @import("std");
const vk = @import("vulkan");
const utils = @import("./utils.zig");
const VulkanContext = @import("./VulkanContext.zig");

// must be kept in sync with shader
pub const InputDescriptorLayout = DescriptorLayout(&.{
    .{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
}, null, "Input");

// must be kept in sync with shader
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
}, null, "Output");

// must be kept in sync with shader
pub const BackgroundDescriptorLayout = DescriptorLayout(&.{
    .{ // image
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // marginal
        .binding = 1,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // conditional
        .binding = 2,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
}, null, "Background");

// must be kept in sync with shader
const max_textures = 20 * 5; // TODO: think about this more, really should
pub const WorldDescriptorLayout = DescriptorLayout(&.{
    .{ // TLAS
        .binding = 0,
        .descriptor_type = .acceleration_structure_khr,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // instances
        .binding = 1,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // worldToInstance
        .binding = 2,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // emitterAliasTable
        .binding = 3,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // meshes
        .binding = 4,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // geometries
        .binding = 5,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // textureSampler
        .binding = 6,
        .descriptor_type = .sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // materialTextures
        .binding = 7,
        .descriptor_type = .sampled_image,
        .descriptor_count = max_textures,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // materialValues
        .binding = 8,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
}, .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{ .partially_bound_bit = true }, .{}, }, "World");

pub fn DescriptorLayout(comptime bindings: []const vk.DescriptorSetLayoutBinding, comptime binding_flags: ?[bindings.len]vk.DescriptorBindingFlags, comptime debug_name: [*:0]const u8) type {
    return struct {
        handle: vk.DescriptorSetLayout,
        pool: vk.DescriptorPool,

        const Self = @This();

        pub fn create(vc: *const VulkanContext, comptime max_sets: comptime_int, layout_flags: vk.DescriptorSetLayoutCreateFlags) !Self {
            const binding_flags_create_info = if (binding_flags) |flags| (&vk.DescriptorSetLayoutBindingFlagsCreateInfo {
                .binding_count = bindings.len,
                .p_binding_flags = &flags,
            }) else null;
            const create_info = vk.DescriptorSetLayoutCreateInfo {
                .flags = layout_flags,
                .binding_count = bindings.len,
                .p_bindings = bindings.ptr,
                .p_next = binding_flags_create_info,
            };
            const handle = try vc.device.createDescriptorSetLayout(&create_info, null);
            errdefer vc.device.destroyDescriptorSetLayout(handle, null);

            try utils.setDebugName(vc, handle, debug_name);

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

        pub fn allocate_set(self: *const Self, vc: *const VulkanContext, writes: [bindings.len]vk.WriteDescriptorSet) !vk.DescriptorSet {
            var descriptor_set: vk.DescriptorSet = undefined;

            try vc.device.allocateDescriptorSets(&.{
                .descriptor_pool = self.pool,
                .descriptor_set_count = 1,
                .p_set_layouts = utils.toPointerType(&self.handle),
            }, @ptrCast([*]vk.DescriptorSet, &descriptor_set));

            var descriptor_writes = writes;
            comptime var k = 0;
            inline while (k < bindings.len) : (k += 1) {
                descriptor_writes[k].dst_set = descriptor_set;
            }

            vc.device.updateDescriptorSets(descriptor_writes.len, &descriptor_writes, 0, undefined);

            return descriptor_set;
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            vc.device.destroyDescriptorPool(self.pool, null);
            vc.device.destroyDescriptorSetLayout(self.handle, null);
        }
    };
}
