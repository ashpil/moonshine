const std = @import("std");
const vk = @import("vulkan");
const Commands = @import("./commands.zig").ComputeCommands;
const VulkanContext = @import("./VulkanContext.zig");
const utils = @import("./utils.zig");

pub const Material = struct {
    metallic: f32,
    ior: f32,
    texture_index: u8,
};

pub fn Accels(comptime blas_count: comptime_int, comptime instance_counts: [blas_count]comptime_int) type {

    comptime var instanced_blas_count = 0;
    comptime for (instance_counts) |count| {
        instanced_blas_count += count;
    };

    return struct {
        // currently, one geometry per BLAS
        pub const BottomLevelAccels = struct {

            handles: [blas_count]vk.AccelerationStructureKHR,
            buffers: [blas_count]vk.Buffer,
            buffers_memory: [blas_count]vk.DeviceMemory,

            instances: vk.Buffer,
            instances_memory: vk.DeviceMemory,

            instance_infos: vk.Buffer,
            instance_infos_memory: vk.DeviceMemory,

            pub fn create(vc: *const VulkanContext, commands: *Commands, geometries: *const [blas_count]vk.AccelerationStructureGeometryKHR, build_infos: *const [blas_count]*const vk.AccelerationStructureBuildRangeInfoKHR, initial_transforms: *const [instanced_blas_count][3][4]f32, materials: [instanced_blas_count]Material) !BottomLevelAccels {
                var geometry_infos: [blas_count]vk.AccelerationStructureBuildGeometryInfoKHR = undefined;

                var scratch_buffers: [blas_count]vk.Buffer = undefined;
                var scratch_buffers_memory: [blas_count]vk.DeviceMemory = undefined;
                defer for (scratch_buffers) |scratch_buffer, i| {
                    vc.device.destroyBuffer(scratch_buffer, null);
                    vc.device.freeMemory(scratch_buffers_memory[i], null);
                };

                var handles: [blas_count]vk.AccelerationStructureKHR = undefined;
                var buffers: [blas_count]vk.Buffer = undefined;
                var buffers_memory: [blas_count]vk.DeviceMemory = undefined;

                comptime var i: usize = 0;
                inline while (i < blas_count) : (i += 1) {
                    geometry_infos[i] = .{
                        .type_ = .bottom_level_khr,
                        .flags = .{ .prefer_fast_trace_bit_khr = true },
                        .mode = .build_khr,
                        .src_acceleration_structure = .null_handle,
                        .dst_acceleration_structure = .null_handle,
                        .geometry_count = 1,
                        .p_geometries = @ptrCast([*]const vk.AccelerationStructureGeometryKHR, &geometries[i]),
                        .pp_geometries = null,
                        .scratch_data = undefined,
                    };

                    const size_info = getBuildSizesInfo(vc, geometry_infos[i], build_infos[i].primitive_count);

                    try utils.createBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true }, .{ .device_local_bit = true }, &scratch_buffers[i], &scratch_buffers_memory[i]);
                    errdefer vc.device.destroyBuffer(scratch_buffers[i], null);
                    errdefer vc.device.freeMemory(scratch_buffers_memory[i], null);

                    try utils.createBuffer(vc, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true }, .{ .device_local_bit = true }, &buffers[i], &buffers_memory[i]);
                    errdefer vc.device.destroyBuffer(buffers[i], null);
                    errdefer vc.device.freeMemory(buffers_memory[i], null);

                    handles[i] = try vc.device.createAccelerationStructureKHR(.{
                        .create_flags = .{},
                        .buffer = buffers[i],
                        .offset = 0,
                        .size = size_info.acceleration_structure_size,
                        .type_ = .bottom_level_khr,
                        .device_address = 0,
                    }, null);
                    geometry_infos[i].dst_acceleration_structure = handles[i];
                    errdefer vc.device.destroyAccelerationStructureKHR(geometry_infos[i].dst_acceleration_structure, null);

                    geometry_infos[i].scratch_data.device_address = vc.device.getBufferDeviceAddress(.{
                        .buffer = scratch_buffers[i],
                    });
                }

                try commands.createAccelStructs(vc, &geometry_infos, build_infos);

                var instances: vk.Buffer = undefined;
                var instances_memory: vk.DeviceMemory = undefined;
                try utils.createBuffer(vc, @sizeOf(vk.AccelerationStructureInstanceKHR) * instanced_blas_count, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }, .{ .device_local_bit = true }, &instances, &instances_memory);
                errdefer vc.device.destroyBuffer(instances, null);
                errdefer vc.device.freeMemory(instances_memory, null);

                var instance_infos: vk.Buffer = undefined;
                var instance_infos_memory: vk.DeviceMemory = undefined;
                try utils.createBuffer(vc, @sizeOf(Material) * instanced_blas_count, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }, .{ .device_local_bit = true }, &instance_infos, &instance_infos_memory);
                errdefer vc.device.destroyBuffer(instance_infos, null);
                errdefer vc.device.freeMemory(instance_infos_memory, null);

                try commands.uploadData(vc, instance_infos, std.mem.asBytes(&materials));

                var self = BottomLevelAccels {
                    .handles = handles,
                    .buffers = buffers,
                    .buffers_memory = buffers_memory,

                    .instances = instances,
                    .instances_memory = instances_memory,

                    .instance_infos = instance_infos,
                    .instance_infos_memory = instance_infos_memory,
                };

                try self.updateInstanceBuffer(vc, commands, initial_transforms);

                return self;
            }

            // this should take in matrix inputs later
            pub fn updateInstanceBuffer(self: *BottomLevelAccels, vc: *const VulkanContext, commands: *Commands, matrices: *const [instanced_blas_count][3][4]f32) !void {

                var instances: [instanced_blas_count]vk.AccelerationStructureInstanceKHR = undefined;

                comptime var offset = 0;
                inline for (instance_counts) |count, i| {
                    comptime var j = 0;
                    inline while (j < count) : (j += 1) {
                        instances[offset + j] = .{
                            .transform = vk.TransformMatrixKHR {
                                .matrix = matrices[offset + j]
                            },
                            .instance_custom_index = i, // we use this in order to differentiate different types of instances - each that has same mesh has same index
                            .mask = 0xFF,
                            .instance_shader_binding_table_record_offset = 0,
                            .flags = 0,
                            .acceleration_structure_reference = vc.device.getAccelerationStructureDeviceAddressKHR(.{
                                .acceleration_structure = self.handles[i],
                            }),
                        };
                    }
                    offset += count;
                }

                try commands.uploadData(vc, self.instances, std.mem.asBytes(&instances));
            }

            pub fn destroy(self: *BottomLevelAccels, vc: *const VulkanContext) void {
                vc.device.destroyBuffer(self.instances, null);
                vc.device.freeMemory(self.instances_memory, null);

                vc.device.destroyBuffer(self.instance_infos, null);
                vc.device.freeMemory(self.instance_infos_memory, null);

                comptime var i: usize = 0;
                inline while (i < blas_count) : (i += 1) {
                    vc.device.destroyAccelerationStructureKHR(self.handles[i], null);
                    vc.device.destroyBuffer(self.buffers[i], null);
                    vc.device.freeMemory(self.buffers_memory[i], null);
                }
            }
        };

        pub const TopLevelAccel = struct {
            handle: vk.AccelerationStructureKHR,
            buffer: vk.Buffer,
            memory: vk.DeviceMemory,

            pub fn create(vc: *const VulkanContext, commands: *Commands, blases: *const BottomLevelAccels) !TopLevelAccel {
                const geometry = vk.AccelerationStructureGeometryKHR {
                    .geometry_type = .instances_khr,
                    .flags = .{ .opaque_bit_khr = true },
                    .geometry = .{
                        .instances = .{
                            .array_of_pointers = vk.FALSE,
                            .data = .{
                                .device_address = vc.device.getBufferDeviceAddress(.{
                                    .buffer = blases.instances,
                                }),
                            }
                        }
                    },
                };

                var geometry_info = vk.AccelerationStructureBuildGeometryInfoKHR {
                    .type_ = .top_level_khr,
                    .flags = .{ .prefer_fast_trace_bit_khr = true },
                    .mode = .build_khr,
                    .src_acceleration_structure = .null_handle,
                    .dst_acceleration_structure = .null_handle,
                    .geometry_count = 1,
                    .p_geometries = @ptrCast([*]const vk.AccelerationStructureGeometryKHR, &geometry),
                    .pp_geometries = null,
                    .scratch_data = undefined,
                };

                const size_info = getBuildSizesInfo(vc, geometry_info, instanced_blas_count);

                var scratch_buffer: vk.Buffer = undefined;
                var scratch_buffer_memory: vk.DeviceMemory = undefined;
                try utils.createBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true }, .{ .device_local_bit = true }, &scratch_buffer, &scratch_buffer_memory);
                defer vc.device.destroyBuffer(scratch_buffer, null);
                defer vc.device.freeMemory(scratch_buffer_memory, null);

                var buffer: vk.Buffer = undefined;
                var memory: vk.DeviceMemory = undefined;
                try utils.createBuffer(vc, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true }, .{ .device_local_bit = true }, &buffer, &memory);
                errdefer vc.device.destroyBuffer(buffer, null);
                errdefer vc.device.freeMemory(memory, null);

                geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(.{
                    .create_flags = .{},
                    .buffer = buffer,
                    .offset = 0,
                    .size = size_info.acceleration_structure_size,
                    .type_ = .top_level_khr,
                    .device_address = 0,
                }, null);
                errdefer vc.device.destroyAccelerationStructureKHR(geometry_info.dst_acceleration_structure, null);

                geometry_info.scratch_data.device_address = vc.device.getBufferDeviceAddress(.{
                    .buffer = scratch_buffer,
                });

                const build_info = .{
                    .primitive_count = instanced_blas_count,
                    .first_vertex = 0,
                    .primitive_offset = 0,
                    .transform_offset = 0,
                };

                try commands.createAccelStructs(vc, &.{ geometry_info }, &.{ &build_info });

                return TopLevelAccel {
                    .handle = geometry_info.dst_acceleration_structure,
                    .buffer = buffer,
                    .memory = memory,
                };
            }

            pub fn destroy(self: *TopLevelAccel, vc: *const VulkanContext) void {
                vc.device.destroyAccelerationStructureKHR(self.handle, null);
                vc.device.destroyBuffer(self.buffer, null);
                vc.device.freeMemory(self.memory, null);
            }
        };
    };
}

fn getBuildSizesInfo(vc: *const VulkanContext, geometry_info: vk.AccelerationStructureBuildGeometryInfoKHR, max_primitive_count: u32) vk.AccelerationStructureBuildSizesInfoKHR {
    var size_info: vk.AccelerationStructureBuildSizesInfoKHR = undefined;
    size_info.s_type = .acceleration_structure_build_sizes_info_khr;
    size_info.p_next = null;
    vc.device.getAccelerationStructureBuildSizesKHR(.device_khr, geometry_info, @ptrCast([*]const u32, &max_primitive_count), &size_info);
    return size_info;
}

