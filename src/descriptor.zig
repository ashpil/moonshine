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

fn isImageWrite(comptime in: type) bool {
    return in == vk.DescriptorImageInfo;
}

fn isAccelWrite(comptime in: type) bool {
    return in == vk.AccelerationStructureKHR;
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

            comptime var bindings: [stages.len]vk.DescriptorSetLayoutBinding = undefined;
            comptime for (bindings) |*binding, i| {
                binding.* = .{
                    .binding = i,
                    .descriptor_type = typeToDescriptorType(@TypeOf(writes[i])),
                    .descriptor_count = 1,
                    .stage_flags = stages[i],
                    .p_immutable_samplers = null,
                };
            };

            const layout = try vc.device.createDescriptorSetLayout(.{
                .flags = .{},
                .binding_count = bindings.len,
                .p_bindings = &bindings,
            }, null);
            errdefer vc.device.destroyDescriptorSetLayout(layout, null);

            // TODO: deduplicate
            comptime var pool_sizes: [stages.len]vk.DescriptorPoolSize = undefined;
            comptime for (pool_sizes) |*pool_size, i| {
                pool_size.* = .{
                    .type_ = typeToDescriptorType(@TypeOf(writes[i])),
                    .descriptor_count = 1,
                };
            };

            const pool = try vc.device.createDescriptorPool(.{
                .flags = .{},
                .max_sets = set_count,
                .pool_size_count = pool_sizes.len,
                .p_pool_sizes = &pool_sizes,
            }, null);
            errdefer vc.device.destroyDescriptorPool(pool, null);

            var descriptor_set_layouts: [set_count]vk.DescriptorSetLayout = undefined;

            comptime var k = 0;
            inline while (k < set_count) : (k += 1) {
                descriptor_set_layouts[k] = layout;
            }

            var descriptor_sets: [set_count]vk.DescriptorSet = undefined;

            try vc.device.allocateDescriptorSets(.{
                .descriptor_pool = pool,
                .descriptor_set_count = set_count,
                .p_set_layouts = &descriptor_set_layouts,
            }, &descriptor_sets);

            comptime var descriptor_write: [stages.len]vk.WriteDescriptorSet = undefined;
            comptime for (descriptor_write) |_, i| {
                descriptor_write[i] = .{
                    .dst_set = undefined, // this can only be set at runtime
                    .dst_binding = i,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = typeToDescriptorType(@TypeOf(writes[i])),
                    .p_buffer_info = undefined,
                    .p_image_info = undefined,
                    .p_texel_buffer_view = undefined,
                    .p_next = null,
                };
            };

            const descriptor_write_count = set_count * stages.len;
            var descriptor_writes: [descriptor_write_count]vk.WriteDescriptorSet = undefined;

            comptime var i = 0;
            inline while (i < descriptor_write_count) : (i = i + stages.len) {
                inline for (descriptor_write) |write_info, j| {
                    descriptor_writes[i+j] = write_info;
                    descriptor_writes[i+j].dst_set = descriptor_sets[i / stages.len];
                    if (isAccelWrite(@TypeOf(writes[j]))) {
                        descriptor_writes[i+j].p_next = &vk.WriteDescriptorSetAccelerationStructureKHR {
                            .acceleration_structure_count = 1,
                            .p_acceleration_structures = @ptrCast([*]const vk.AccelerationStructureKHR, &writes[j]),
                        };
                    } else if (isImageWrite(@TypeOf(writes[j]))) {
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

        pub fn write(self: *const Self, vc: *const VulkanContext, comptime dst_binding: comptime_int, write_info: anytype) void {
            var descriptor_writes: [set_count]vk.WriteDescriptorSet = undefined;
            comptime var i = 0;
            inline while (i < set_count) : (i += 1) {
                descriptor_writes[i] = .{
                    .dst_set = self.sets[i],
                    .dst_binding = dst_binding,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = typeToDescriptorType(@TypeOf(write_info)),
                    .p_buffer_info = undefined,
                    .p_image_info = if (isImageWrite(@TypeOf(write_info))) @ptrCast([*]const vk.DescriptorImageInfo, &write_info) else undefined,
                    .p_texel_buffer_view = undefined,
                    .p_next = if (isAccelWrite(@TypeOf(write_info))) &vk.WriteDescriptorSetAccelerationStructureKHR {
                                .acceleration_structure_count = 1,
                                .p_acceleration_structures = @ptrCast([*]const vk.AccelerationStructureKHR, &write_info),
                            } else null,
                };
            }

            vc.device.updateDescriptorSets(descriptor_writes.len, &descriptor_writes, 0, undefined);
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            vc.device.destroyDescriptorPool(self.pool, null);
            vc.device.destroyDescriptorSetLayout(self.layout, null);
        }
    };
}