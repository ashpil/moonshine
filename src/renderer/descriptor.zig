const std = @import("std");
const vk = @import("vulkan");
const VulkanContext = @import("./VulkanContext.zig");

pub const StorageImage = struct {
    view: vk.ImageView,

    const count = 1;
    
    fn toDescriptor(self: StorageImage) [1]vk.DescriptorImageInfo {
        return [1]vk.DescriptorImageInfo {
            .{
                .sampler = .null_handle,
                .image_view = self.view,
                .image_layout = .general,
            }
        };
    }
};

pub const Texture = struct {
    view: vk.ImageView,
    sampler: vk.Sampler,

    const count = 1;

    fn toDescriptor(self: Texture) [1]vk.DescriptorImageInfo {
        return [1]vk.DescriptorImageInfo {
            .{
                .sampler = self.sampler,
                .image_view = self.view,
                .image_layout = .shader_read_only_optimal,
            }
        };
    }
};

pub const Sampler = struct {
    sampler: vk.Sampler,

    const count = 1;

    fn toDescriptor(self: Sampler) [1]vk.DescriptorImageInfo {
        return [1]vk.DescriptorImageInfo {
            .{
                .sampler = self.sampler,
                .image_view = .null_handle,
                .image_layout = undefined,
            }
        };
    }
};

pub fn TextureArray(comptime texture_count: comptime_int) type {
    return struct {
        views: [texture_count]vk.ImageView,

        const count = texture_count;

        fn toDescriptor(self: @This()) [texture_count]vk.DescriptorImageInfo {
            var infos: [texture_count]vk.DescriptorImageInfo = undefined;
            comptime var i = 0;
            inline while (i < texture_count) : (i += 1) {
                infos[i] = vk.DescriptorImageInfo {
                    .sampler = .null_handle,
                    .image_view = self.views[i],
                    .image_layout = .shader_read_only_optimal,
                };
            }

            return infos;
        }
    };
}

pub const StorageBuffer = struct {
    buffer: vk.Buffer,

    const count = 1;

    fn toDescriptor(self: StorageBuffer) [1]vk.DescriptorBufferInfo {
        return [1]vk.DescriptorBufferInfo {
            .{
                .range = vk.WHOLE_SIZE,
                .offset = 0,
                .buffer = self.buffer,
            }
        };
    }
};

fn typeToDescriptorType(comptime in: type) vk.DescriptorType {
    return switch (in) {
        StorageBuffer => .storage_buffer,
        StorageImage => .storage_image,
        Texture => .combined_image_sampler,
        Sampler => .sampler,
        vk.AccelerationStructureKHR => .acceleration_structure_khr,
        else => {
            if (std.mem.indexOf(u8, @typeName(in), "TextureArray")) |_| {
                return .sampled_image;
            }
            @compileError("Unknown input type: " ++ @typeName(in));
        }
    };
}

fn isImageWrite(comptime in: type) bool {
    return in == StorageImage or in == Texture or in == Sampler or (if (std.mem.indexOf(u8, @typeName(in), "TextureArray")) |_| true else false);
}

fn isAccelWrite(comptime in: type) bool {
    return in == vk.AccelerationStructureKHR;
}

fn isBufferWrite(comptime in: type) bool {
    return in == StorageBuffer;
}

pub const BindingInfo = struct {
    stage_flags: vk.ShaderStageFlags,
    descriptor_type: vk.DescriptorType,
    count: u32, 
};

pub fn Descriptor(comptime set_count: comptime_int) type {
    return struct {
        const Self = @This();

        pool: vk.DescriptorPool,
        layout: vk.DescriptorSetLayout,
        sets: [set_count]vk.DescriptorSet,

        pub fn create(vc: *const VulkanContext, comptime binding_infos: anytype) !Self {
            comptime var bindings: [binding_infos.len]vk.DescriptorSetLayoutBinding = undefined;
            comptime for (bindings) |*binding, i| {
                binding.* = .{
                    .binding = i,
                    .descriptor_type = binding_infos[i].descriptor_type,
                    .descriptor_count = binding_infos[i].count,
                    .stage_flags = binding_infos[i].stage_flags,
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
            comptime var pool_sizes: [binding_infos.len]vk.DescriptorPoolSize = undefined;
            comptime for (pool_sizes) |*pool_size, i| {
                pool_size.* = .{
                    .type_ =  binding_infos[i].descriptor_type,
                    .descriptor_count = binding_infos[i].count,
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

            return Self {
                .layout = layout,
                .pool = pool,
                .sets = descriptor_sets,
            };
        }

        // expects `write_info` to be a tuple of descriptors
        // expects `dst_bindings` is an array of `comptime_int`s specifying their respective write info dst binding
        // expects `dst_sets` is an array of `u32`s specifying their respective set index
        // currently only supports images I think
        pub fn write(self: *const Self, vc: *const VulkanContext, comptime dst_bindings: anytype, dst_sets: anytype, write_infos: anytype) void {
            comptime if (dst_bindings.len != write_infos.len) @compileError("`dst_bindings` and `write_info` must have same length!");

            comptime var descriptor_write: [dst_bindings.len]vk.WriteDescriptorSet = undefined;
            comptime for (descriptor_write) |_, i| {
                descriptor_write[i] = vk.WriteDescriptorSet {
                    .dst_set = undefined, // this can only be set at runtime
                    .dst_binding = dst_bindings[i],
                    .dst_array_element = 0,
                    .descriptor_count = if (isAccelWrite(@TypeOf(write_infos[i]))) 1 else @TypeOf(write_infos[i]).count,
                    .descriptor_type = typeToDescriptorType(@TypeOf(write_infos[i])),
                    .p_buffer_info = undefined,
                    .p_image_info = undefined,
                    .p_texel_buffer_view = undefined,
                    .p_next = null,
                };
            };

            const descriptor_write_count = dst_sets.len * dst_bindings.len;
            var descriptor_writes: [descriptor_write_count]vk.WriteDescriptorSet = undefined;

            comptime var i = 0;
            inline while (i < descriptor_write_count) : (i = i + dst_bindings.len) {
                inline for (descriptor_write) |write_info, j| {
                    descriptor_writes[i+j] = write_info;
                    descriptor_writes[i+j].dst_set = self.sets[i / dst_bindings.len];
                    if (comptime isAccelWrite(@TypeOf(write_infos[j]))) {
                        descriptor_writes[i+j].p_next = &vk.WriteDescriptorSetAccelerationStructureKHR {
                            .acceleration_structure_count = 1,
                            .p_acceleration_structures = @ptrCast([*]const vk.AccelerationStructureKHR, &write_infos[j]),
                        };
                    } else if (comptime isImageWrite(@TypeOf(write_infos[j]))) {
                        descriptor_writes[i+j].p_image_info = @ptrCast([*]const vk.DescriptorImageInfo, &write_infos[j].toDescriptor());
                    } else if (comptime isBufferWrite(@TypeOf(write_infos[j]))) {
                        descriptor_writes[i+j].p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &write_infos[j].toDescriptor());
                    }
                }
            }

            vc.device.updateDescriptorSets(descriptor_write_count, &descriptor_writes, 0, undefined);
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            vc.device.destroyDescriptorPool(self.pool, null);
            vc.device.destroyDescriptorSetLayout(self.layout, null);
        }
    };
}