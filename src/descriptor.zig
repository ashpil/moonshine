const std = @import("std");
const vk = @import("vulkan");
const VulkanContext = @import("./VulkanContext.zig");

fn typeToDescriptorType(comptime in: type) vk.DescriptorType {
    return switch (in) {
        vk.AccelerationStructureKHR => .acceleration_structure_khr,
        vk.DescriptorImageInfo => .storage_image,
        else => @compileError("Unknown input type: " ++ @typeName(in)),
    };
}

pub fn Descriptor(comptime set_count: comptime_int) type {
    return struct {
        const Self = @This();

        pool: vk.DescriptorPool,
        layout: vk.DescriptorSetLayout,
        sets: [set_count]vk.DescriptorSet,

        pub fn create(vc: *const VulkanContext, comptime stages: anytype, writes: anytype) !Self {
            comptime if (!std.meta.trait.isTuple(@TypeOf(stages))) @compileError("Stages must be a tuple of ShaderStageFlags");
            comptime if (!std.meta.trait.isTuple(@TypeOf(writes))) @compileError("Writes must be a tuple");
            comptime if (stages.len != writes.len) @compileError("Must have same amount of writes and flags");

            const bindings = comptime blk: {
                var comp_bindings: [stages.len]vk.DescriptorSetLayoutBinding = undefined;
                for (comp_bindings) |*comp_binding, i| {
                    comp_binding.* = .{
                        .binding = i,
                        .descriptor_type = typeToDescriptorType(@TypeOf(writes[i])),
                        .descriptor_count = 1,
                        .stage_flags = stages[i],
                        .p_immutable_samplers = null,
                    };
                }
                break :blk comp_bindings;
            };

            const layout = try vc.device.createDescriptorSetLayout(.{
                .flags = .{},
                .binding_count = bindings.len,
                .p_bindings = &bindings,
            }, null);

            // TODO: deduplicate
            const pool_sizes = comptime blk: {
                var comp_pool_sizes: [stages.len]vk.DescriptorPoolSize = undefined;
                for (comp_pool_sizes) |*comp_pool_size, i| {
                    comp_pool_size.* = .{
                        .type_ = typeToDescriptorType(@TypeOf(writes[i])),
                        .descriptor_count = 1,
                    };
                }
                break :blk comp_pool_sizes;
            };

            const pool = try vc.device.createDescriptorPool(.{
                .flags = .{},
                .max_sets = set_count,
                .pool_size_count = pool_sizes.len,
                .p_pool_sizes = &pool_sizes,
            }, null);

            var descriptor_set_layouts: [set_count]vk.DescriptorSetLayout = undefined;

            for (descriptor_set_layouts) |*descriptor_set_layout| {
                descriptor_set_layout.* = layout;
            }

            var descriptor_sets: [set_count]vk.DescriptorSet = undefined;

            try vc.device.allocateDescriptorSets(.{
                .descriptor_pool = pool,
                .descriptor_set_count = set_count,
                .p_set_layouts = &descriptor_set_layouts,
            }, &descriptor_sets);

            const descriptor_write = comptime blk: {
                var comp_descriptor_writes: [stages.len]vk.WriteDescriptorSet = undefined;
                for (comp_descriptor_writes) |*comp_descriptor_write, i| {
                    comp_descriptor_write.* = .{
                        .dst_set = undefined, // this can only be set at runtime
                        .dst_binding = i,
                        .dst_array_element = 0,
                        .descriptor_count = 1,
                        .descriptor_type = typeToDescriptorType(@TypeOf(writes[i])),
                        .p_buffer_info = undefined,
                        .p_image_info = undefined,
                        .p_texel_buffer_view = undefined,
                        .p_next = undefined,
                    };
                }
                break :blk comp_descriptor_writes;
            };

            const descriptor_write_count = set_count * stages.len;
            var descriptor_writes: [descriptor_write_count]vk.WriteDescriptorSet = undefined;

            comptime var i = 0;
            inline while (i < descriptor_write_count) : (i = i + stages.len) {
                inline for (descriptor_write) |write, j| {
                    descriptor_writes[i+j] = write;
                    descriptor_writes[i+j].dst_set = descriptor_sets[i / stages.len];
                    if (@TypeOf(writes[j]) == vk.AccelerationStructureKHR) {
                        descriptor_writes[i+j].p_next = &vk.WriteDescriptorSetAccelerationStructureKHR {
                            .acceleration_structure_count = 1,
                            .p_acceleration_structures = @ptrCast([*]const vk.AccelerationStructureKHR, &writes[j]),
                        };
                    } else if (@TypeOf(writes[j]) == vk.DescriptorImageInfo) {
                        descriptor_writes[i+j].p_image_info = @ptrCast([*]const vk.DescriptorImageInfo, &writes[j]);
                    }
                }
            }
            
            vc.device.updateDescriptorSets(descriptor_write_count, &descriptor_writes, 0, undefined);

            return Self {
                .layout = layout,
                .pool = pool,
                .sets = descriptor_sets,
            };
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            vc.device.destroyDescriptorPool(self.pool, null);
            vc.device.destroyDescriptorSetLayout(self.layout, null);
        }
    };
}