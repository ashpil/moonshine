const std = @import("std");
const vk = @import("vulkan");
const core = @import("../engine.zig").core;
const vk_helpers = core.vk_helpers;
const VulkanContext = core.VulkanContext;

const DescriptorBindingInfo = struct {
    descriptor_type: vk.DescriptorType,
    descriptor_count: u32,
    stage_flags: vk.ShaderStageFlags,
    binding_flags: vk.DescriptorBindingFlags = .{},
};

pub fn DescriptorLayout(comptime bindings: []const DescriptorBindingInfo, comptime layout_flags: vk.DescriptorSetLayoutCreateFlags, comptime max_sets: comptime_int, comptime debug_name: [*:0]const u8) type {
    return struct {
        handle: vk.DescriptorSetLayout,
        pool: vk.DescriptorPool,

        const Self = @This();

        pub fn create(vc: *const VulkanContext) !Self {
            comptime var vk_bindings: [bindings.len]vk.DescriptorSetLayoutBinding = undefined;
            comptime var vk_binding_flags: [bindings.len]vk.DescriptorBindingFlags = undefined;
            comptime for (bindings, &vk_bindings, &vk_binding_flags, 0..) |binding, *vk_binding, *vk_binding_flag, binding_index| {
                vk_binding.* = vk.DescriptorSetLayoutBinding {
                    .binding = binding_index,
                    .descriptor_type = binding.descriptor_type,
                    .descriptor_count = binding.descriptor_count,
                    .stage_flags = binding.stage_flags,
                };
                vk_binding_flag.* = binding.binding_flags;
            };
            const create_info = vk.DescriptorSetLayoutCreateInfo {
                .flags = layout_flags,
                .binding_count = bindings.len,
                .p_bindings = &vk_bindings,
                .p_next = @ptrCast(&vk.DescriptorSetLayoutBindingFlagsCreateInfo {
                    .binding_count = bindings.len,
                    .p_binding_flags = &vk_binding_flags,
                }),
            };
            const handle = try vc.device.createDescriptorSetLayout(&create_info, null);
            errdefer vc.device.destroyDescriptorSetLayout(handle, null);

            try vk_helpers.setDebugName(vc, handle, debug_name);

            comptime var pool_sizes: [bindings.len]vk.DescriptorPoolSize = undefined;
            comptime for (&pool_sizes, bindings) |*pool_size, binding| {
                pool_size.* = .{
                    .type =  binding.descriptor_type,
                    .descriptor_count = binding.descriptor_count * max_sets,
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

            try vc.device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo {
                .descriptor_pool = self.pool,
                .descriptor_set_count = 1,
                .p_set_layouts = @ptrCast(&self.handle),
            }, @ptrCast(&descriptor_set));

            // avoid writing descriptors in certain invalid states:
            // 1. descriptor count is zero
            // 2. buffer is vk_null_handle
            var valid_writes: [bindings.len]vk.WriteDescriptorSet = undefined;
            var valid_write_count: u32 = 0;
            for (writes) |write| {
                if (write.descriptor_count == 0) continue;
                switch (write.descriptor_type) {
                    .storage_buffer => if (write.p_buffer_info[0].buffer == .null_handle) continue,
                    else => {},
                }

                valid_writes[valid_write_count] = write;
                valid_writes[valid_write_count].dst_set = descriptor_set;
                valid_write_count += 1;
            }

            vc.device.updateDescriptorSets(valid_write_count, &valid_writes, 0, undefined);

            return descriptor_set;
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            vc.device.destroyDescriptorPool(self.pool, null);
            vc.device.destroyDescriptorSetLayout(self.handle, null);
        }
    };
}
