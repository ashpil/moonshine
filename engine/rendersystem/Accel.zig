const std = @import("std");
const vk = @import("vulkan");
const Commands = @import("./Commands.zig");
const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const utils = @import("./utils.zig");
const Mat3x4 = @import("../vector.zig").Mat3x4(f32);

pub const Instances = std.MultiArrayList(struct {
    mesh_info: MeshInfo,
    material_index: u32,
});

pub const MeshInfo = struct {
    transform: Mat3x4,
    mesh_index: u24,
    visible: bool = true,
};

pub const GeometryInfos = std.MultiArrayList(struct {
    geometry: vk.AccelerationStructureGeometryKHR,
    build_info: *const vk.AccelerationStructureBuildRangeInfoKHR,
});

const BottomLevelAccels = std.MultiArrayList(struct {
    handle: vk.AccelerationStructureKHR,
    buffer: VkAllocator.DeviceBuffer,
    address: vk.DeviceAddress,
});

blases: BottomLevelAccels,

instance_infos: VkAllocator.HostBuffer(vk.AccelerationStructureInstanceKHR),

instance_buffer: VkAllocator.DeviceBuffer,
instance_count: u32,

tlas_handle: vk.AccelerationStructureKHR,
tlas_buffer: VkAllocator.DeviceBuffer,
tlas_device_address: vk.DeviceAddress,

tlas_update_scratch_buffer: VkAllocator.DeviceBuffer,
tlas_update_scratch_address: vk.DeviceAddress,

changed: bool,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, geometry_infos: GeometryInfos, instances: Instances) !Self {

    const instance_count = @intCast(u32, instances.len);
    const geometry_infos_slice = geometry_infos.slice();

    const buffers = try allocator.alloc(VkAllocator.OwnedDeviceBuffer, geometry_infos.len);
    defer allocator.free(buffers);
    defer for (buffers) |buffer| {
        buffer.destroy(vc);
    };

    const handles = try allocator.alloc(vk.AccelerationStructureKHR, geometry_infos.len);
    defer allocator.free(handles);
    defer for (handles) |handle| {
        vc.device.destroyAccelerationStructureKHR(handle, null);
    };
    
    const blases = blk: {
        var build_geometry_infos = try allocator.alloc(vk.AccelerationStructureBuildGeometryInfoKHR, geometry_infos.len);
        defer allocator.free(build_geometry_infos);

        const scratch_buffers = try allocator.alloc(VkAllocator.OwnedDeviceBuffer, geometry_infos.len);
        defer allocator.free(scratch_buffers);
        defer for (scratch_buffers) |scratch_buffer| {
            scratch_buffer.destroy(vc);
        };

        const geometries = geometry_infos_slice.items(.geometry);
        const build_infos = geometry_infos_slice.items(.build_info);

        for (geometries) |*geometry, i| {
            build_geometry_infos[i] = .{
                .@"type" = .bottom_level_khr,
                .flags = .{ .prefer_fast_trace_bit_khr = true, .allow_compaction_bit_khr = true },
                .mode = .build_khr,
                .src_acceleration_structure = .null_handle,
                .dst_acceleration_structure = .null_handle,
                .geometry_count = 1,
                .p_geometries = utils.toPointerType(geometry),
                .pp_geometries = null,
                .scratch_data = undefined,
            };
            const size_info = getBuildSizesInfo(vc, &build_geometry_infos[i], build_infos[i].primitive_count);

            scratch_buffers[i] = try vk_allocator.createOwnedDeviceBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true });
            errdefer scratch_buffers[i].destroy(vc);
            build_geometry_infos[i].scratch_data.device_address = scratch_buffers[i].getAddress(vc);

            buffers[i] = try vk_allocator.createOwnedDeviceBuffer(vc, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true });
            errdefer buffers[i].destroy(vc);

            build_geometry_infos[i].dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(&.{
                .create_flags = .{},
                .buffer = buffers[i].handle,
                .offset = 0,
                .size = size_info.acceleration_structure_size,
                .@"type" = .bottom_level_khr,
                .device_address = 0,
            }, null);
            errdefer vc.device.destroyAccelerationStructureKHR(build_geometry_infos[i].dst_acceleration_structure, null);

            handles[i] = build_geometry_infos[i].dst_acceleration_structure;
        }

        const compactedSizes = try allocator.alloc(vk.DeviceSize, geometry_infos.len);
        defer allocator.free(compactedSizes);
        try commands.createAccelStructsAndGetCompactedSizes(vc, build_geometry_infos, build_infos, handles, compactedSizes);

        var blases = BottomLevelAccels {};
        try blases.ensureTotalCapacity(allocator, geometry_infos.len);
        errdefer blases.deinit(allocator);

        const copy_infos = try allocator.alloc(vk.CopyAccelerationStructureInfoKHR, geometry_infos.len);
        defer allocator.free(copy_infos);

        for (compactedSizes) |compactedSize, i| {
            const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, compactedSize, .{ .acceleration_structure_storage_bit_khr = true });
            errdefer buffer.destroy(vc);

            const handle = try vc.device.createAccelerationStructureKHR(&.{
                .create_flags = .{},
                .buffer = buffer.handle,
                .offset = 0,
                .size = compactedSize,
                .@"type" = .bottom_level_khr,
                .device_address = 0,
            }, null);

            copy_infos[i] = .{
                .src = handles[i],
                .dst = handle,
                .mode = .compact_khr,
            };

            blases.appendAssumeCapacity(.{
                .handle = handle,
                .buffer = buffer,
                .address = vc.device.getAccelerationStructureDeviceAddressKHR(&.{
                    .acceleration_structure = handle,
                }),
            });
        }

        try commands.copyAccelStructs(vc, copy_infos);

        break :blk blases;
    };

    // create instance info
    const instance_infos = try vk_allocator.createHostBuffer(vc, vk.AccelerationStructureInstanceKHR, instance_count, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
    errdefer instance_infos.destroy(vc);

    // create tlas
    const geometry = vk.AccelerationStructureGeometryKHR {
        .geometry_type = .instances_khr,
        .flags = .{ .opaque_bit_khr = true },
        .geometry = .{
            .instances = .{
                .array_of_pointers = vk.FALSE,
                .data = .{
                    .device_address = instance_infos.getAddress(vc),
                }
            }
        },
    };

    var geometry_info = vk.AccelerationStructureBuildGeometryInfoKHR {
        .@"type" = .top_level_khr,
        .flags = .{ .prefer_fast_trace_bit_khr = true, .allow_update_bit_khr = true },
        .mode = .build_khr,
        .src_acceleration_structure = .null_handle,
        .dst_acceleration_structure = .null_handle,
        .geometry_count = 1,
        .p_geometries = utils.toPointerType(&geometry),
        .pp_geometries = null,
        .scratch_data = undefined,
    };

    const size_info = getBuildSizesInfo(vc, &geometry_info, instance_count);

    const scratch_buffer = try vk_allocator.createOwnedDeviceBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true });
    defer scratch_buffer.destroy(vc);

    const tlas_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true });
    errdefer tlas_buffer.destroy(vc);

    geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(&.{
        .create_flags = .{},
        .buffer = tlas_buffer.handle,
        .offset = 0,
        .size = size_info.acceleration_structure_size,
        .@"type" = .top_level_khr,
        .device_address = 0,
    }, null);
    errdefer vc.device.destroyAccelerationStructureKHR(geometry_info.dst_acceleration_structure, null);

    geometry_info.scratch_data.device_address = scratch_buffer.getAddress(vc);

    const update_scratch_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, size_info.update_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true });
    errdefer update_scratch_buffer.destroy(vc);

    const instance_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(u32) * instance_count, .{ .shader_device_address_bit = true, .storage_buffer_bit = true, .transfer_dst_bit = true });
    errdefer instance_buffer.destroy(vc);
    try commands.uploadData(vc, vk_allocator, instance_buffer.handle, .{ .bytes = std.mem.sliceAsBytes(instances.items(.material_index)) });

    var accel = Self {
        .blases = blases,

        .instance_infos = instance_infos,

        .tlas_device_address = geometry.geometry.instances.data.device_address,
        .tlas_handle = geometry_info.dst_acceleration_structure,
        .tlas_buffer = tlas_buffer,

        .tlas_update_scratch_buffer = update_scratch_buffer,
        .tlas_update_scratch_address = update_scratch_buffer.getAddress(vc),

        .instance_buffer = instance_buffer,
        .instance_count = instance_count,

        .changed = false,
    };

    const instance_data = instances.items(.mesh_info);
    accel.updateInstanceBuffer(instance_data);

    const build_info = .{
        .primitive_count = instance_count,
        .first_vertex = 0,
        .primitive_offset = 0,
        .transform_offset = 0,
    };
    try commands.createAccelStructs(vc, &.{ geometry_info }, &.{ &build_info });
    
    return accel;
}

pub fn updateInstanceBuffer(self: *Self, mesh_infos: []const MeshInfo) void {
    const blas_addresses = self.blases.items(.address);

    for (mesh_infos) |mesh_info, i| {
        const mesh_index = mesh_info.mesh_index;
        self.instance_infos.data[i] = .{
            .transform = vk.TransformMatrixKHR {
                .matrix = @bitCast([3][4]f32, mesh_info.transform),
            },
            .instance_custom_index = mesh_index,
            .mask = if (mesh_info.visible) 0xFF else 0x00,
            .instance_shader_binding_table_record_offset = 0,
            .flags = 0,
            .acceleration_structure_reference = blas_addresses[mesh_index],
        };
    } 
}

pub fn updateTlas(self: *Self, mesh_infos: []const MeshInfo) void {
    self.updateInstanceBuffer(mesh_infos);

    self.changed = true;
}

pub fn recordInstanceUpdate(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, instance_index: u32, new_value: u32) void {
    vc.device.cmdUpdateBuffer(command_buffer, self.instance_buffer.handle, @sizeOf(u32) * instance_index, @sizeOf(u32), &new_value);

    const barrier = vk.BufferMemoryBarrier2 {
        .src_stage_mask = .{ .copy_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
        .dst_access_mask = .{ .shader_storage_read_bit = true },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .buffer = self.instance_buffer.handle,
        .offset = @sizeOf(u32) * instance_index,
        .size = @sizeOf(u32),
    };
    vc.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = undefined,
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = utils.toPointerType(&barrier),
        .image_memory_barrier_count = 0,
        .p_image_memory_barriers = undefined,
    });
}

pub fn recordChanges(self: *Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer) !void {
    if (self.changed) {
        const geometry = vk.AccelerationStructureGeometryKHR {
            .geometry_type = .instances_khr,
            .flags = .{ .opaque_bit_khr = true },
            .geometry = .{
                .instances = .{
                    .array_of_pointers = vk.FALSE,
                    .data = .{
                        .device_address = self.tlas_device_address,
                    }
                }
            },
        };

        var geometry_info = vk.AccelerationStructureBuildGeometryInfoKHR {
            .@"type" = .top_level_khr,
            .flags = .{ .prefer_fast_trace_bit_khr = true, .allow_update_bit_khr = true },
            .mode = .update_khr,
            .src_acceleration_structure = self.tlas_handle,
            .dst_acceleration_structure = self.tlas_handle,
            .geometry_count = 1,
            .p_geometries = utils.toPointerType(&geometry),
            .pp_geometries = null,
            .scratch_data = .{
                .device_address = self.tlas_update_scratch_address,
            },
        };

        const build_info = vk.AccelerationStructureBuildRangeInfoKHR {
            .primitive_count = self.instance_count,
            .first_vertex = 0,
            .primitive_offset = 0,
            .transform_offset = 0,
        };

        const build_info_ref = &build_info;

        vc.device.cmdBuildAccelerationStructuresKHR(command_buffer, 1, utils.toPointerType(&geometry_info), utils.toPointerType(&build_info_ref));

        const barriers = [_]vk.MemoryBarrier2 {
            .{
                .src_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
                .src_access_mask = .{ .acceleration_structure_write_bit_khr = true },
                .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true },
            }
        };
        vc.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
            .dependency_flags = .{},
            .memory_barrier_count = barriers.len,
            .p_memory_barriers = &barriers,
            .buffer_memory_barrier_count = 0,
            .p_buffer_memory_barriers = undefined,
            .image_memory_barrier_count = 0,
            .p_image_memory_barriers = undefined,
        });
    }
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.instance_infos.destroy(vc);

    self.instance_buffer.destroy(vc);
    self.tlas_update_scratch_buffer.destroy(vc);

    const blases_slice = self.blases.slice();
    const blases_handles = blases_slice.items(.handle);
    const blases_buffers = blases_slice.items(.buffer);

    var i: u32 = 0;
    while (i < self.blases.len) : (i += 1) {
        vc.device.destroyAccelerationStructureKHR(blases_handles[i], null);
        blases_buffers[i].destroy(vc);
    }
    self.blases.deinit(allocator);

    vc.device.destroyAccelerationStructureKHR(self.tlas_handle, null);
    self.tlas_buffer.destroy(vc);
}

fn getBuildSizesInfo(vc: *const VulkanContext, geometry_info: *const vk.AccelerationStructureBuildGeometryInfoKHR, max_primitive_count: u32) vk.AccelerationStructureBuildSizesInfoKHR {
    var size_info: vk.AccelerationStructureBuildSizesInfoKHR = undefined;
    size_info.s_type = .acceleration_structure_build_sizes_info_khr;
    size_info.p_next = null;
    vc.device.getAccelerationStructureBuildSizesKHR(.device_khr, geometry_info, utils.toPointerType(&max_primitive_count), &size_info);
    return size_info;
}
