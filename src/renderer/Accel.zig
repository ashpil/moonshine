const std = @import("std");
const vk = @import("vulkan");
const Commands = @import("./commands.zig").ComputeCommands;
const VulkanContext = @import("./VulkanContext.zig");
const utils = @import("./utils.zig");
const Mat3x4 = @import("../utils/zug.zig").Mat3x4(f32);

pub const Instances = std.MultiArrayList(struct {
    mesh_info: MeshInfo,
    material_index: u32,
});

pub const MeshInfo = struct {
    transform: Mat3x4,
    mesh_index: u24,
};

pub const GeometryInfos = std.MultiArrayList(struct {
    geometry: vk.AccelerationStructureGeometryKHR,
    build_info: *const vk.AccelerationStructureBuildRangeInfoKHR,
});

const BottomLevelAccels = std.MultiArrayList(struct {
    handle: vk.AccelerationStructureKHR,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    address: vk.DeviceAddress,
});

blases: BottomLevelAccels,

instance_infos_host: []vk.AccelerationStructureInstanceKHR,
instance_infos_buffer: vk.Buffer,
instance_infos_memory: vk.DeviceMemory,

instance_buffer: vk.Buffer,
instance_memory: vk.DeviceMemory,

tlas_device_address: vk.DeviceAddress,
tlas_handle: vk.AccelerationStructureKHR,
tlas_buffer: vk.Buffer,
tlas_memory: vk.DeviceMemory,

tlas_update_scratch_device_address: vk.DeviceAddress,
tlas_update_scratch_buffer: vk.Buffer,
tlas_update_scratch_memory: vk.DeviceMemory,

const Self = @This();

pub fn create(vc: *const VulkanContext, allocator: *std.mem.Allocator, commands: *Commands, geometry_infos: GeometryInfos, instances: Instances) !Self {

    const instance_count = @intCast(u32, instances.len);
    const geometry_infos_slice = geometry_infos.slice();

    const memories = try allocator.alloc(vk.DeviceMemory, geometry_infos.len);
    defer allocator.free(memories);
    defer for (memories) |memory| {
        vc.device.freeMemory(memory, null);
    };

    const buffers = try allocator.alloc(vk.Buffer, geometry_infos.len);
    defer allocator.free(buffers);
    defer for (buffers) |buffer| {
        vc.device.destroyBuffer(buffer, null);
    };

    const handles = try allocator.alloc(vk.AccelerationStructureKHR, geometry_infos.len);
    defer allocator.free(handles);
    defer for (handles) |handle| {
        vc.device.destroyAccelerationStructureKHR(handle, null);
    };
    
    const blases = blk: {
        var build_geometry_infos = try allocator.alloc(vk.AccelerationStructureBuildGeometryInfoKHR, geometry_infos.len);
        defer allocator.free(build_geometry_infos);

        var scratch_buffers = try allocator.alloc(vk.Buffer, geometry_infos.len);
        defer allocator.free(scratch_buffers);
        var scratch_buffers_memory = try allocator.alloc(vk.DeviceMemory, geometry_infos.len);
        defer allocator.free(scratch_buffers_memory);
        defer for (scratch_buffers) |scratch_buffer, i| {
            vc.device.destroyBuffer(scratch_buffer, null);
            vc.device.freeMemory(scratch_buffers_memory[i], null);
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
            const size_info = getBuildSizesInfo(vc, build_geometry_infos[i], build_infos[i].primitive_count);

            try utils.createBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true }, .{ .device_local_bit = true }, &scratch_buffers[i], &scratch_buffers_memory[i]);
            errdefer vc.device.freeMemory(scratch_buffers_memory[i], null);
            errdefer vc.device.destroyBuffer(scratch_buffers[i], null);
            build_geometry_infos[i].scratch_data.device_address = vc.device.getBufferDeviceAddress(.{
                .buffer = scratch_buffers[i],
            });

            try utils.createBuffer(vc, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true }, .{ .device_local_bit = true }, &buffers[i], &memories[i]);
            errdefer vc.device.destroyBuffer(buffers[i], null);
            errdefer vc.device.freeMemory(memories[i], null);

            build_geometry_infos[i].dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(.{
                .create_flags = .{},
                .buffer = buffers[i],
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
            var buffer: vk.Buffer = undefined;
            var memory: vk.DeviceMemory = undefined;
            try utils.createBuffer(vc, compactedSize, .{ .acceleration_structure_storage_bit_khr = true }, .{ .device_local_bit = true }, &buffer, &memory);
            errdefer vc.device.destroyBuffer(buffer, null);
            errdefer vc.device.freeMemory(memory, null);

            const handle = try vc.device.createAccelerationStructureKHR(.{
                .create_flags = .{},
                .buffer = buffer,
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
                .memory = memory,
                .address = vc.device.getAccelerationStructureDeviceAddressKHR(.{
                    .acceleration_structure = handle,
                }),
            });
        }

        try commands.copyAccelStructs(vc, copy_infos);

        break :blk blases;
    };

    // create instance info
    var instance_infos_buffer: vk.Buffer = undefined;
    var instance_infos_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, @sizeOf(vk.AccelerationStructureInstanceKHR) * instance_count, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &instance_infos_buffer, &instance_infos_memory);
    errdefer vc.device.freeMemory(instance_infos_memory, null);
    errdefer vc.device.destroyBuffer(instance_infos_buffer, null);

    const instance_infos_host = @ptrCast([*]vk.AccelerationStructureInstanceKHR, (try vc.device.mapMemory(instance_infos_memory, 0, @sizeOf(vk.AccelerationStructureInstanceKHR) * instance_count, .{})).?)[0..instance_count];

    // create tlas
    const geometry = vk.AccelerationStructureGeometryKHR {
        .geometry_type = .instances_khr,
        .flags = .{ .opaque_bit_khr = true },
        .geometry = .{
            .instances = .{
                .array_of_pointers = vk.FALSE,
                .data = .{
                    .device_address = vc.device.getBufferDeviceAddress(.{
                        .buffer = instance_infos_buffer,
                    }),
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

    const size_info = getBuildSizesInfo(vc, geometry_info, instance_count);

    var scratch_buffer: vk.Buffer = undefined;
    var scratch_buffer_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true }, .{ .device_local_bit = true }, &scratch_buffer, &scratch_buffer_memory);
    defer vc.device.destroyBuffer(scratch_buffer, null);
    defer vc.device.freeMemory(scratch_buffer_memory, null);

    var tlas_buffer: vk.Buffer = undefined;
    var tlas_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true }, .{ .device_local_bit = true }, &tlas_buffer, &tlas_memory);
    errdefer vc.device.freeMemory(tlas_memory, null);
    errdefer vc.device.destroyBuffer(tlas_buffer, null);

    geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(.{
        .create_flags = .{},
        .buffer = tlas_buffer,
        .offset = 0,
        .size = size_info.acceleration_structure_size,
        .@"type" = .top_level_khr,
        .device_address = 0,
    }, null);
    errdefer vc.device.destroyAccelerationStructureKHR(geometry_info.dst_acceleration_structure, null);

    geometry_info.scratch_data.device_address = vc.device.getBufferDeviceAddress(.{
        .buffer = scratch_buffer,
    });

    var update_scratch_buffer: vk.Buffer = undefined;
    var update_scratch_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, size_info.update_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true }, .{ .device_local_bit = true }, &update_scratch_buffer, &update_scratch_memory);

    var instance_buffer: vk.Buffer = undefined;
    var instance_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, @sizeOf(u32) * instance_count, .{ .shader_device_address_bit = true, .storage_buffer_bit = true, .transfer_dst_bit = true }, .{ .device_local_bit = true }, &instance_buffer, &instance_memory);
    try commands.uploadData(vc, instance_buffer, std.mem.sliceAsBytes(instances.items(.material_index)));

    var accel = Self {
        .blases = blases,

        .instance_infos_buffer = instance_infos_buffer,
        .instance_infos_memory = instance_infos_memory,
        .instance_infos_host = instance_infos_host,

        .tlas_device_address = geometry.geometry.instances.data.device_address,
        .tlas_handle = geometry_info.dst_acceleration_structure,
        .tlas_buffer = tlas_buffer,
        .tlas_memory = tlas_memory,

        .tlas_update_scratch_device_address = vc.device.getBufferDeviceAddress(.{
            .buffer = update_scratch_buffer,
        }),
        .tlas_update_scratch_buffer = update_scratch_buffer,
        .tlas_update_scratch_memory = update_scratch_memory,

        .instance_buffer = instance_buffer,
        .instance_memory = instance_memory,
    };

    const instance_data = instances.items(.mesh_info);
    try accel.updateInstanceBuffer(instance_data);

    const build_info = .{
        .primitive_count = instance_count,
        .first_vertex = 0,
        .primitive_offset = 0,
        .transform_offset = 0,
    };
    try commands.createAccelStructs(vc, &.{ geometry_info }, &.{ &build_info });
    
    return accel;
}

pub fn updateInstanceBuffer(self: *Self, mesh_infos: []const MeshInfo) !void {
    const blas_addresses = self.blases.items(.address);

    for (mesh_infos) |mesh_info, i| {
        const mesh_index = mesh_info.mesh_index;
        self.instance_infos_host[i] = .{
            .transform = vk.TransformMatrixKHR {
                .matrix = @bitCast([3][4]f32, mesh_info.transform),
            },
            .instance_custom_index = mesh_index,
            .mask = 0xFF,
            .instance_shader_binding_table_record_offset = 0,
            .flags = 0,
            .acceleration_structure_reference = blas_addresses[mesh_index],
        };
    } 
}

pub fn updateTlas(self: *Self, vc: *const VulkanContext, commands: *Commands, mesh_infos: []const MeshInfo) !void {
    try self.updateInstanceBuffer(mesh_infos);

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
            .device_address = self.tlas_update_scratch_device_address,
        },
    };

    const build_info = .{
        .primitive_count = @intCast(u32, mesh_infos.len),
        .first_vertex = 0,
        .primitive_offset = 0,
        .transform_offset = 0,
    };

    // todo: make this usable on a per-frame basis
    try commands.createAccelStructs(vc, &.{ geometry_info }, &.{ &build_info });
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator) void {
    vc.device.destroyBuffer(self.instance_infos_buffer, null);
    vc.device.unmapMemory(self.instance_infos_memory);
    vc.device.freeMemory(self.instance_infos_memory, null);

    vc.device.destroyBuffer(self.instance_buffer, null);
    vc.device.freeMemory(self.instance_memory, null);

    vc.device.destroyBuffer(self.tlas_update_scratch_buffer, null);
    vc.device.freeMemory(self.tlas_update_scratch_memory, null);

    const blases_slice = self.blases.slice();
    const blases_handles = blases_slice.items(.handle);
    const blases_buffers = blases_slice.items(.buffer);
    const blases_buffers_memory = blases_slice.items(.memory);

    var i: u32 = 0;
    while (i < self.blases.len) : (i += 1) {
        vc.device.destroyAccelerationStructureKHR(blases_handles[i], null);
        vc.device.destroyBuffer(blases_buffers[i], null);
        vc.device.freeMemory(blases_buffers_memory[i], null);
    }
    self.blases.deinit(allocator);

    vc.device.destroyAccelerationStructureKHR(self.tlas_handle, null);
    vc.device.destroyBuffer(self.tlas_buffer, null);
    vc.device.freeMemory(self.tlas_memory, null);
}

fn getBuildSizesInfo(vc: *const VulkanContext, geometry_info: vk.AccelerationStructureBuildGeometryInfoKHR, max_primitive_count: u32) vk.AccelerationStructureBuildSizesInfoKHR {
    var size_info: vk.AccelerationStructureBuildSizesInfoKHR = undefined;
    size_info.s_type = .acceleration_structure_build_sizes_info_khr;
    size_info.p_next = null;
    vc.device.getAccelerationStructureBuildSizesKHR(.device_khr, geometry_info, utils.toPointerType(&max_primitive_count), &size_info);
    return size_info;
}

