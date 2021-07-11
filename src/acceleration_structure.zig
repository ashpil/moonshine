const std = @import("std");
const vk = @import("vulkan");
const Meshes = @import("./mesh.zig").Meshes;
const Commands = @import("./commands.zig").ComputeCommands;
const VulkanContext = @import("./vulkan_context.zig").VulkanContext;
const utils = @import("./utils.zig");

// currently, one geometry per BLAS
pub fn BottomLevelAccels(comptime comp_vc: *VulkanContext, comptime comp_allocator: *std.mem.Allocator) type {

    const BottomLevelAccelStorage = std.MultiArrayList(struct {
        handle: vk.AccelerationStructureKHR,
        buffer: vk.Buffer,
        memory: vk.DeviceMemory,
    });
    
    return struct {
        storage: BottomLevelAccelStorage,

        instances: vk.Buffer,
        instances_memory: vk.DeviceMemory,

        const Self = @This();

        const vc = comp_vc;
        const allocator = comp_allocator;

        pub fn create(commands: *Commands(comp_vc), meshes: Meshes(comp_vc, comp_allocator)) !Self {
            const num_accels = meshes.storage.len;

            var storage = BottomLevelAccelStorage {};
            try storage.ensureTotalCapacity(allocator, num_accels);

            const geometry_infos = try allocator.alloc(vk.AccelerationStructureBuildGeometryInfoKHR, num_accels);
            defer allocator.free(geometry_infos);

            const scratch_buffers = try allocator.alloc(vk.Buffer, num_accels);
            const scratch_buffers_memory = try allocator.alloc(vk.DeviceMemory, num_accels);
            defer allocator.free(scratch_buffers);
            defer allocator.free(scratch_buffers_memory);
            defer for (scratch_buffers) |scratch_buffer, i| {
                vc.device.destroyBuffer(scratch_buffer, null);
                vc.device.freeMemory(scratch_buffers_memory[i], null);
            };

            var i: usize = 0;

            const slice = meshes.storage.slice();
            const geometries = slice.items(.geometry);
            const build_infos = slice.items(.build_info);

            while (i < num_accels) : (i += 1) {
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

                const size_info = getBuildSizesInfo(vc, geometry_infos[i], @ptrCast([*]const u32, &build_infos[i].primitive_count));

                try utils.createBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true }, .{ .device_local_bit = true }, &scratch_buffers[i], &scratch_buffers_memory[i]);

                var buffer: vk.Buffer = undefined;
                var memory: vk.DeviceMemory = undefined;
                try utils.createBuffer(vc, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true }, .{ .device_local_bit = true }, &buffer, &memory);

                geometry_infos[i].dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(.{
                    .create_flags = .{},
                    .buffer = buffer,
                    .offset = 0,
                    .size = size_info.acceleration_structure_size,
                    .type_ = .bottom_level_khr,
                    .device_address = 0,
                }, null);

                geometry_infos[i].scratch_data.device_address = vc.device.getBufferDeviceAddress(.{
                    .buffer = scratch_buffers[i],
                });

                storage.appendAssumeCapacity(.{
                    .handle = geometry_infos[i].dst_acceleration_structure,
                    .buffer = buffer,
                    .memory = memory,
                });
            }

            try commands.createAccelStructs(geometry_infos, build_infos);

            var instances: vk.Buffer = undefined;
            var instances_memory: vk.DeviceMemory = undefined;
            try utils.createBuffer(vc, @sizeOf(vk.AccelerationStructureInstanceKHR) * storage.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true}, .{ .device_local_bit = true }, &instances, &instances_memory);

            var self = Self {
                .storage = storage,
                .instances = instances,
                .instances_memory = instances_memory,
            };

            try self.updateInstanceBuffer(commands);

            return self;
        }

        // this should take in matrix inputs later
        pub fn updateInstanceBuffer(self: *Self, commands: *Commands(comp_vc)) !void {
            const instances = try allocator.alloc(vk.AccelerationStructureInstanceKHR, self.storage.len);
            defer allocator.free(instances);

            const identity = vk.TransformMatrixKHR {
                .matrix = .{
                    .{1.0, 0.0, 0.0, 0.0},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.0},
                }
            };
            const handles = self.storage.items(.handle);

            for (instances) |_, i| {
                instances[i] = .{
                    .transform = identity,
                    .instance_custom_index = 0,
                    .mask = 0xFF,
                    .instance_shader_binding_table_record_offset = 0,
                    .flags = 0,
                    .acceleration_structure_reference = vc.device.getAccelerationStructureDeviceAddressKHR(.{
                        .acceleration_structure = handles[i],
                    }),
                };
            }

            try commands.uploadData(self.instances, @bitCast([]u8, handles)); // a bit weird but works I think?
        }

        pub fn destroy(self: *Self) void {
            vc.device.destroyBuffer(self.instances, null);
            vc.device.freeMemory(self.instances_memory, null);

            const slice = self.storage.slice();
            for (slice.items(.handle)) |handle| {
                vc.device.destroyAccelerationStructureKHR(handle, null);
            }
            for (slice.items(.buffer)) |buffer| {
                vc.device.destroyBuffer(buffer, null);
            }
            for (slice.items(.memory)) |memory| {
                vc.device.freeMemory(memory, null);
            }
            self.storage.deinit(allocator);
        }
    };
}

pub fn TopLevelAccel(comptime comp_vc: *VulkanContext, comptime comp_allocator: *std.mem.Allocator) type {
    return struct {
        handle: vk.AccelerationStructureKHR,
        buffer: vk.Buffer,
        memory: vk.DeviceMemory,

        const Self = @This();

        const vc = comp_vc;

        pub fn create(commands: *Commands(comp_vc), blases: *BottomLevelAccels(comp_vc, comp_allocator)) !Self {
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

            const size_info = getBuildSizesInfo(vc, geometry_info, @ptrCast([*]const u32, &blases.storage.len));

            var scratch_buffer: vk.Buffer = undefined;
            var scratch_buffer_memory: vk.DeviceMemory = undefined;
            defer vc.device.destroyBuffer(scratch_buffer, null);
            defer vc.device.freeMemory(scratch_buffer_memory, null);
            try utils.createBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true }, .{ .device_local_bit = true }, &scratch_buffer, &scratch_buffer_memory);

            var buffer: vk.Buffer = undefined;
            var memory: vk.DeviceMemory = undefined;
            try utils.createBuffer(vc, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true }, .{ .device_local_bit = true }, &buffer, &memory);

            geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(.{
                .create_flags = .{},
                .buffer = buffer,
                .offset = 0,
                .size = size_info.acceleration_structure_size,
                .type_ = .top_level_khr,
                .device_address = 0,
            }, null);

            geometry_info.scratch_data.device_address = vc.device.getBufferDeviceAddress(.{
                .buffer = scratch_buffer,
            });

            const build_info = .{
                .primitive_count = @intCast(u32, blases.storage.len),
                .first_vertex = 0,
                .primitive_offset = 0,
                .transform_offset = 0,
            };

            try commands.createAccelStructs(&.{ geometry_info }, &.{ &build_info });

            return Self {
                .handle = geometry_info.dst_acceleration_structure,
                .buffer = buffer,
                .memory = memory,
            };
        }

        pub fn destroy(self: *Self) void {
            vc.device.destroyAccelerationStructureKHR(self.handle, null);
            vc.device.destroyBuffer(self.buffer, null);
            vc.device.freeMemory(self.memory, null);
        }
    };
}


fn getBuildSizesInfo(vc: *VulkanContext, geometry_info: vk.AccelerationStructureBuildGeometryInfoKHR, max_primitive_counts: [*]const u32) vk.AccelerationStructureBuildSizesInfoKHR {
    var size_info: vk.AccelerationStructureBuildSizesInfoKHR = undefined;
    size_info.s_type = .acceleration_structure_build_sizes_info_khr;
    size_info.p_next = null;
    vc.device.getAccelerationStructureBuildSizesKHR(.device_khr, geometry_info, max_primitive_counts, &size_info);
    return size_info;
}
