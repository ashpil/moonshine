const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const VulkanContext = engine.core.VulkanContext;
const Commands = engine.core.Commands;
const VkAllocator = engine.core.Allocator;
const vk_helpers = engine.core.vk_helpers;

const MeshManager = @import("./MeshManager.zig");
const AliasTable = @import("./alias_table.zig").AliasTable;

const vector = @import("../vector.zig");
const Mat3x4 = vector.Mat3x4(f32);
const F32x3 = vector.Vec3(f32);

// "accel" perhaps the wrong name for this struct at this point, maybe "heirarchy" would be better
// the acceleration structure is the primary world heirarchy, and controls
// how all the meshes and materials fit together
//
// an acceleration structure has:
// - a list of instances
//
// each instance has:
// - a transform
// - a visible flag
// - a list of geometries
//
// each geometry (BLAS) has:
// - a mesh
// - a material
// - a sampled (for emitted light) flag

pub const Instance = struct {
    transform: Mat3x4, // transform of this instance
    visible: bool = true, // whether this instance is visible
    geometries: []const Geometry, // geometries in this instance
};

pub const Geometry = extern struct {
    mesh: u32, // idx of mesh that this geometry uses
    material: u32, // idx of material that this geometry uses
    sampled: bool, // whether this geometry is explicitly sampled for emitted light
};

const BottomLevelAccels = std.MultiArrayList(struct {
    handle: vk.AccelerationStructureKHR,
    buffer: VkAllocator.DeviceBuffer(u8),
});

const TableData = extern struct {
    instance: u32,
    geometry: u32,
    primitive: u32,
};
const AliasTableT = AliasTable(TableData);

blases: BottomLevelAccels = .{},

instance_count: u32 = 0,
instances_device: VkAllocator.DeviceBuffer(vk.AccelerationStructureInstanceKHR) = .{},
instances_host: VkAllocator.HostBuffer(vk.AccelerationStructureInstanceKHR) = .{},
instances_address: vk.DeviceAddress = 0,

// keep track of inverse transform -- non-inverse we can get from instances_device
// transforms provided by shader only in hit/intersection shaders but we need them
// in raygen
// ray queries provide them in any shader which would be a benefit of using them
world_to_instance_device: VkAllocator.DeviceBuffer(Mat3x4) = .{},
world_to_instance_host: VkAllocator.HostBuffer(Mat3x4) = .{},

// flat jagged array for geometries --
// use instanceCustomIndex + GeometryID() here to get geometry
geometry_count: u24 = 0,
geometries: VkAllocator.DeviceBuffer(Geometry) = .{},

// tlas stuff
tlas_handle: vk.AccelerationStructureKHR = .null_handle,
tlas_buffer: VkAllocator.DeviceBuffer(u8) = .{},

tlas_update_scratch_buffer: VkAllocator.DeviceBuffer(u8) = .{},
tlas_update_scratch_address: vk.DeviceAddress = 0,

alias_table: VkAllocator.DeviceBuffer(AliasTableT.TableEntry) = .{}, // to sample lights

const Self = @This();

const max_instances = 4096; // TODO: resizable buffers
const max_geometries = 4096; // TODO: resizable buffers

// lots of temp memory allocations here
fn makeBlases(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, mesh_manager: MeshManager, geometries: []const []const Geometry, blases: *BottomLevelAccels) !void {
    const uncompacted_buffers = try allocator.alloc(VkAllocator.OwnedDeviceBuffer, geometries.len);
    defer allocator.free(uncompacted_buffers);
    defer for (uncompacted_buffers) |buffer| buffer.destroy(vc);

    const uncompacted_blases = try allocator.alloc(vk.AccelerationStructureKHR, geometries.len);
    defer allocator.free(uncompacted_blases);
    defer for (uncompacted_blases) |handle| vc.device.destroyAccelerationStructureKHR(handle, null);

    const build_geometry_infos = try allocator.alloc(vk.AccelerationStructureBuildGeometryInfoKHR, geometries.len);
    defer allocator.free(build_geometry_infos);
    defer for (build_geometry_infos) |build_geometry_info| allocator.free(build_geometry_info.p_geometries.?[0..build_geometry_info.geometry_count]);

    const scratch_buffers = try allocator.alloc(VkAllocator.OwnedDeviceBuffer, geometries.len);
    defer allocator.free(scratch_buffers);
    defer for (scratch_buffers) |scratch_buffer| scratch_buffer.destroy(vc);

    const build_infos = try allocator.alloc([*]vk.AccelerationStructureBuildRangeInfoKHR, geometries.len);
    defer allocator.free(build_infos);
    defer for (build_infos, build_geometry_infos) |build_info, build_geometry_info| allocator.free(build_info[0..build_geometry_info.geometry_count]);

    for (geometries, build_infos, build_geometry_infos, scratch_buffers, uncompacted_buffers, uncompacted_blases) |list, *build_info, *build_geometry_info, *scratch_buffer, *uncompacted_buffer, *uncompacted_blas| {
        const vk_geometries = try allocator.alloc(vk.AccelerationStructureGeometryKHR, list.len);

        build_geometry_info.* = vk.AccelerationStructureBuildGeometryInfoKHR {
            .type = .bottom_level_khr,
            .flags = .{ .prefer_fast_trace_bit_khr = true, .allow_compaction_bit_khr = true },
            .mode = .build_khr,
            .geometry_count = @intCast(vk_geometries.len),
            .p_geometries = vk_geometries.ptr,
            .scratch_data = undefined,
        };

        const primitive_counts = try allocator.alloc(u32, list.len);
        defer allocator.free(primitive_counts);

        build_info.* = (try allocator.alloc(vk.AccelerationStructureBuildRangeInfoKHR, list.len)).ptr;

        for (list, vk_geometries, primitive_counts, 0..) |geo, *geometry, *primitive_count, j| {
            const mesh = mesh_manager.meshes.get(geo.mesh);

            geometry.* = vk.AccelerationStructureGeometryKHR {
                .geometry_type = .triangles_khr,
                .flags = .{ .opaque_bit_khr = true },
                .geometry = .{
                    .triangles = .{
                        .vertex_format = .r32g32b32_sfloat,
                        .vertex_data = .{
                            .device_address = mesh.position_buffer.getAddress(vc),
                        },
                        .vertex_stride = @sizeOf(F32x3),
                        .max_vertex = @intCast(mesh.vertex_count - 1),
                        .index_type = .uint32,
                        .index_data = .{
                            .device_address = mesh.index_buffer.getAddress(vc),
                        },
                        .transform_data = .{
                            .device_address = 0,
                        }
                    }
                }
            };

            build_info.*[j] =  vk.AccelerationStructureBuildRangeInfoKHR {
                .primitive_count = @intCast(mesh.index_count),
                .primitive_offset = 0,
                .transform_offset = 0,
                .first_vertex = 0,
            };
            primitive_count.* = build_info.*[j].primitive_count;
        }

        const size_info = getBuildSizesInfo(vc, build_geometry_info, primitive_counts.ptr);

        scratch_buffer.* = try vk_allocator.createOwnedDeviceBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true });
        errdefer scratch_buffer.destroy(vc);
        build_geometry_info.scratch_data.device_address = scratch_buffer.getAddress(vc);

        uncompacted_buffer.* = try vk_allocator.createOwnedDeviceBuffer(vc, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true });
        errdefer uncompacted_buffer.destroy(vc);

        build_geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(&.{
            .buffer = uncompacted_buffer.handle,
            .offset = 0,
            .size = size_info.acceleration_structure_size,
            .type = .bottom_level_khr,
        }, null);
        errdefer vc.device.destroyAccelerationStructureKHR(build_geometry_info.dst_acceleration_structure, null);

        uncompacted_blas.* = build_geometry_info.dst_acceleration_structure;
    }

    const compactedSizes = try allocator.alloc(vk.DeviceSize, geometries.len);
    defer allocator.free(compactedSizes);
    if (compactedSizes.len != 0) try commands.createAccelStructsAndGetCompactedSizes(vc, build_geometry_infos, build_infos, uncompacted_blases, compactedSizes);

    try blases.ensureUnusedCapacity(allocator, geometries.len);

    const copy_infos = try allocator.alloc(vk.CopyAccelerationStructureInfoKHR, geometries.len);
    defer allocator.free(copy_infos);

    for (compactedSizes, copy_infos, uncompacted_blases) |compactedSize, *copy_info, uncompacted_blas| {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, u8, compactedSize, .{ .acceleration_structure_storage_bit_khr = true });
        errdefer buffer.destroy(vc);

        const handle = try vc.device.createAccelerationStructureKHR(&.{
            .buffer = buffer.handle,
            .offset = 0,
            .size = compactedSize,
            .type = .bottom_level_khr,
        }, null);

        copy_info.* = .{
            .src = uncompacted_blas,
            .dst = handle,
            .mode = .compact_khr,
        };

        blases.appendAssumeCapacity(.{
            .handle = handle,
            .buffer = buffer,
        });
    }

    try commands.copyAccelStructs(vc, copy_infos);
}

// accel must not be in use
// alias table currently unimplemented
pub const Handle = u32;
pub fn uploadInstance(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, mesh_manager: MeshManager, instance: Instance) !Handle {
    std.debug.assert(self.geometry_count + instance.geometries.len <= max_geometries);
    std.debug.assert(self.instance_count < max_instances);

    try makeBlases(vc, vk_allocator, allocator, commands, mesh_manager, &.{ instance.geometries }, &self.blases);

    // update geometries flat jagged array
    {
        if (self.geometries.is_null()) {
            self.geometries = try vk_allocator.createDeviceBuffer(vc, allocator, Geometry, max_geometries, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
            try vk_helpers.setDebugName(vc, self.geometries.handle, "geometries");
        }

        try commands.startRecording(vc);
        commands.recordUpdateBuffer(Geometry, vc, self.geometries, instance.geometries, self.geometry_count);
        try commands.submitAndIdleUntilDone(vc);

        self.geometry_count += @intCast(instance.geometries.len);
    }

    // upload instance
    {
        if (self.instances_device.is_null()) {
            self.instances_device = try vk_allocator.createDeviceBuffer(vc, allocator, vk.AccelerationStructureInstanceKHR, max_instances, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true, .storage_buffer_bit = true });
            self.instances_host = try vk_allocator.createHostBuffer(vc, vk.AccelerationStructureInstanceKHR, max_instances, .{ .transfer_src_bit = true });
            try vk_helpers.setDebugName(vc, self.instances_device.handle, "instances");
            self.instances_address = self.instances_device.getAddress(vc);
        }

        const custom_index: u24 = self.geometry_count - @as(u24, @intCast(instance.geometries.len));
        const vk_instance = vk.AccelerationStructureInstanceKHR {
            .transform = vk.TransformMatrixKHR {
                .matrix = @bitCast(instance.transform),
            },
            .instance_custom_index_and_mask = .{
                .instance_custom_index = custom_index,
                .mask = if (instance.visible) 0xFF else 0x00,
            },
            .instance_shader_binding_table_record_offset_and_flags = .{
                .instance_shader_binding_table_record_offset = 0,
                .flags = 0,
            },
            .acceleration_structure_reference = vc.device.getAccelerationStructureDeviceAddressKHR(&.{
                .acceleration_structure = self.blases.items(.handle)[self.blases.len - 1],
            }),
        };

        self.instances_host.data[self.instance_count] = vk_instance;

        try commands.startRecording(vc);
        commands.recordUpdateBuffer(vk.AccelerationStructureInstanceKHR, vc, self.instances_device, &.{ vk_instance }, self.instance_count); // TODO: can copy
        try commands.submitAndIdleUntilDone(vc);
    }

    // upload world_to_instance matrix
    {
        if (self.world_to_instance_device.is_null()) {
            self.world_to_instance_device = try vk_allocator.createDeviceBuffer(vc, allocator, Mat3x4, max_instances, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
            self.world_to_instance_host = try vk_allocator.createHostBuffer(vc, Mat3x4, max_instances, .{ .transfer_src_bit = true });
        }

        self.world_to_instance_host.data[self.instance_count] = instance.transform.inverse_affine();

        try commands.startRecording(vc);
        commands.recordUpdateBuffer(Mat3x4, vc, self.world_to_instance_device, &.{ instance.transform.inverse_affine() }, self.instance_count);
        try commands.submitAndIdleUntilDone(vc);
    }

    self.instance_count += 1;

    // update TLAS
    var geometry_info = vk.AccelerationStructureBuildGeometryInfoKHR {
        .type = .top_level_khr,
        .flags = .{ .prefer_fast_trace_bit_khr = true, .allow_update_bit_khr = true },
        .mode = .build_khr,
        .geometry_count = 1,
        .p_geometries = @ptrCast(&vk.AccelerationStructureGeometryKHR {
            .geometry_type = .instances_khr,
            .flags = .{ .opaque_bit_khr = true },
            .geometry = .{
                .instances = .{
                    .array_of_pointers = vk.FALSE,
                    .data = .{
                        .device_address = self.instances_address,
                    }
                }
            },
        }),
        .scratch_data = undefined,
    };

    const size_info = getBuildSizesInfo(vc, &geometry_info, @ptrCast(&self.instance_count));

    const scratch_buffer = try vk_allocator.createOwnedDeviceBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true });
    defer scratch_buffer.destroy(vc);

    self.tlas_buffer.destroy(vc);
    self.tlas_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, u8, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true });

    vc.device.destroyAccelerationStructureKHR(self.tlas_handle, null);
    geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(&.{
        .buffer = self.tlas_buffer.handle,
        .offset = 0,
        .size = size_info.acceleration_structure_size,
        .type = .top_level_khr,
    }, null);
    self.tlas_handle = geometry_info.dst_acceleration_structure;

    geometry_info.scratch_data.device_address = scratch_buffer.getAddress(vc);

    self.tlas_update_scratch_buffer.destroy(vc);
    self.tlas_update_scratch_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, u8, size_info.update_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true });
    self.tlas_update_scratch_address = self.tlas_update_scratch_buffer.getAddress(vc);

    try commands.createAccelStructs(vc, &.{ geometry_info }, &[_][*]const vk.AccelerationStructureBuildRangeInfoKHR{ @ptrCast(&vk.AccelerationStructureBuildRangeInfoKHR {
        .primitive_count = @intCast(self.instance_count),
        .first_vertex = 0,
        .primitive_offset = 0,
        .transform_offset = 0,
    })});

    return @intCast(self.instance_count - 1);
}

// inspection bool specifies whether some buffers should be created with the `transfer_src_flag` for inspection
pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, mesh_manager: MeshManager, instances: []const Instance, inspection: bool) !Self {
    // as an optimization, see if any instances contain identical mesh lists,
    // because we only need to create as many BLASes as there are unique mesh lists
    var unique_mesh_lists_hash = std.ArrayHashMap([]const Geometry, u32, struct {
        const Context = @This();
        pub fn hash(self: Context, key: []const Geometry) u32 {
            _ = self;
            var wy = std.hash.Wyhash.init(0);
            for (key) |geo| {
                wy.update(std.mem.asBytes(&geo.mesh));
            }
            return @truncate(wy.final());
        }
        pub fn eql(self: Context, key1: []const Geometry, key2: []const Geometry, b_index: usize) bool {
            _ = self;
            _ = b_index;
            // like mem.eql but only checks meshes
            if (key1.len != key2.len) return false;
            if (key1.ptr == key2.ptr) return true;
            for (key1, key2) |a, b| {
                if (a.mesh != b.mesh) return false;
            }
            return true;
        }
    }, false).init(allocator); // last param maybe should be true
    defer unique_mesh_lists_hash.deinit();

    var idx: u32 = 0;
    for (instances) |instance| {
        const res = try unique_mesh_lists_hash.getOrPutValue(instance.geometries, idx);
        if (!res.found_existing) idx += 1;
    }

    // create a BLAS for each model
    var blases = BottomLevelAccels {};
    errdefer blases.deinit(allocator);
    try makeBlases(vc, vk_allocator, allocator, commands, mesh_manager, unique_mesh_lists_hash.keys(), &blases);

    // create geometries flat jagged array
    var total_geometry_count: u24 = 0;
    const geometries = blk: {
        for (instances) |instance| {
            total_geometry_count += @intCast(instance.geometries.len);
        }
        const geometries_host = try vk_allocator.createHostBuffer(vc, Geometry, total_geometry_count, .{ .transfer_src_bit = true });
        defer geometries_host.destroy(vc);

        var buffer_flags = vk.BufferUsageFlags { .storage_buffer_bit = true, .transfer_dst_bit = true };
        if (inspection) buffer_flags = buffer_flags.merge(.{ .transfer_src_bit = true });
        const geometries = try vk_allocator.createDeviceBuffer(vc, allocator, Geometry, total_geometry_count, buffer_flags);
        errdefer geometries.destroy(vc);
        try vk_helpers.setDebugName(vc, geometries.handle, "geometries");

        var flat_idx: u32 = 0;
        for (instances) |instance| {
            for (instance.geometries) |geometry| {
                geometries_host.data[flat_idx] = geometry;
                flat_idx += 1;
            }
        }

        if (total_geometry_count != 0) {
            try commands.startRecording(vc);
            commands.recordUploadBuffer(Geometry, vc, geometries, geometries_host);
            try commands.submitAndIdleUntilDone(vc);
        }

        break :blk geometries;
    };
    errdefer geometries.destroy(vc);

    // create instance
    const instance_count: u32 = @intCast(instances.len);
    const instances_host = try vk_allocator.createHostBuffer(vc, vk.AccelerationStructureInstanceKHR, instance_count, .{ .transfer_src_bit = true });
    const instances_device = blk: {
        var instances_buffer_flags = vk.BufferUsageFlags { .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true, .storage_buffer_bit = true };
        if (inspection) instances_buffer_flags = instances_buffer_flags.merge(.{ .transfer_src_bit = true });
        const instances_device = try vk_allocator.createDeviceBuffer(vc, allocator, vk.AccelerationStructureInstanceKHR, instance_count, instances_buffer_flags);
        errdefer instances_device.destroy(vc);
        try vk_helpers.setDebugName(vc, instances_device.handle, "instances");

        var custom_index: u24 = 0;
        for (instances_host.data, instances) |*instance_host, instance| {
            instance_host.* = .{
                .transform = vk.TransformMatrixKHR {
                    .matrix = @bitCast(instance.transform),
                },
                .instance_custom_index_and_mask = .{
                    .instance_custom_index = custom_index,
                    .mask = if (instance.visible) 0xFF else 0x00,
                },
                .instance_shader_binding_table_record_offset_and_flags = .{
                    .instance_shader_binding_table_record_offset = 0,
                    .flags = 0,
                },
                .acceleration_structure_reference = vc.device.getAccelerationStructureDeviceAddressKHR(&.{
                    .acceleration_structure = blases.items(.handle)[unique_mesh_lists_hash.get(instance.geometries).?],
                }),
            };
            custom_index += @intCast(instance.geometries.len);
        }

        if (instance_count != 0) {
            try commands.startRecording(vc);
            commands.recordUploadBuffer(vk.AccelerationStructureInstanceKHR, vc, instances_device, instances_host);
            try commands.submitAndIdleUntilDone(vc);
        }

        break :blk instances_device;
    };
    errdefer instances_device.destroy(vc);

    const instances_address = instances_device.getAddress(vc);

    const world_to_instance_host = try vk_allocator.createHostBuffer(vc, Mat3x4, instance_count, .{ .transfer_src_bit = true });
    const world_to_instance_device = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, Mat3x4, instance_count, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        for (instances, world_to_instance_host.data) |instance, *inverse| {
            inverse.* = instance.transform.inverse_affine();
        }

        if (instance_count != 0) {
            try commands.startRecording(vc);
            commands.recordUploadBuffer(Mat3x4, vc, buffer, world_to_instance_host);
            try commands.submitAndIdleUntilDone(vc);
        }

        break :blk buffer;
    };
    errdefer world_to_instance_device.destroy(vc);

    // create TLAS
    var geometry_info = vk.AccelerationStructureBuildGeometryInfoKHR {
        .type = .top_level_khr,
        .flags = .{ .prefer_fast_trace_bit_khr = true, .allow_update_bit_khr = true },
        .mode = .build_khr,
        .geometry_count = 1,
        .p_geometries = @ptrCast(&vk.AccelerationStructureGeometryKHR {
            .geometry_type = .instances_khr,
            .flags = .{ .opaque_bit_khr = true },
            .geometry = .{
                .instances = .{
                    .array_of_pointers = vk.FALSE,
                    .data = .{
                        .device_address = instances_address,
                    }
                }
            },
        }),
        .scratch_data = undefined,
    };

    const size_info = getBuildSizesInfo(vc, &geometry_info, @ptrCast(&instance_count));

    const scratch_buffer = try vk_allocator.createOwnedDeviceBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true });
    defer scratch_buffer.destroy(vc);

    const tlas_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, u8, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true });
    errdefer tlas_buffer.destroy(vc);

    geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(&.{
        .buffer = tlas_buffer.handle,
        .offset = 0,
        .size = size_info.acceleration_structure_size,
        .type = .top_level_khr,
    }, null);
    errdefer vc.device.destroyAccelerationStructureKHR(geometry_info.dst_acceleration_structure, null);

    geometry_info.scratch_data.device_address = scratch_buffer.getAddress(vc);

    const update_scratch_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, u8, size_info.update_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true });
    errdefer update_scratch_buffer.destroy(vc);

    try commands.createAccelStructs(vc, &.{ geometry_info }, &[_][*]const vk.AccelerationStructureBuildRangeInfoKHR{ @ptrCast(&vk.AccelerationStructureBuildRangeInfoKHR {
        .primitive_count = instance_count,
        .first_vertex = 0,
        .primitive_offset = 0,
        .transform_offset = 0,
    })});

    const alias_table = blk: {

        var weights = std.ArrayList(f32).init(allocator);
        defer weights.deinit();

        var table_data = std.ArrayList(TableData).init(allocator);
        defer table_data.deinit();

        for (instances, 0..) |instance, i| {
            for (instance.geometries, 0..) |instance_geometry, j| {
                if (!instance_geometry.sampled) continue;

                const mesh_idx = instance_geometry.mesh;
                const positions = mesh_manager.meshes.items(.positions)[mesh_idx];
                const indices = mesh_manager.meshes.items(.indices)[mesh_idx];
                for (indices, 0..) |index, k| {
                    const p0 = instance.transform.mul_point(positions[index.x]);
                    const p1 = instance.transform.mul_point(positions[index.y]);
                    const p2 = instance.transform.mul_point(positions[index.z]);
                    const area = p1.sub(p0).cross(p2.sub(p0)).length() / 2.0;
                    try weights.append(area);
                    try table_data.append(.{
                        .instance = @intCast(i),
                        .geometry = @intCast(j),
                        .primitive = @intCast(k),
                    });
                }
            }
        }

        const table = try AliasTableT.create(allocator, weights.items, table_data.items);
        defer allocator.free(table.entries);

        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, AliasTableT.TableEntry, table.entries.len + 1, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const staging_buffer = try vk_allocator.createHostBuffer(vc, AliasTableT.TableEntry, table.entries.len + 1, .{ .transfer_src_bit = true });
        defer staging_buffer.destroy(vc);

        staging_buffer.data[0].alias = @intCast(table.entries.len);
        staging_buffer.data[0].select = table.sum;
        @memcpy(staging_buffer.data[1..], table.entries);

        try commands.startRecording(vc);
        commands.recordUploadBuffer(AliasTableT.TableEntry, vc, buffer, staging_buffer);
        try commands.submitAndIdleUntilDone(vc);

        break :blk buffer;
    };
    errdefer alias_table.destroy(vc);

    return Self {
        .blases = blases,

        .instances_device = instances_device,
        .instances_host = instances_host,
        .instances_address = instances_address,

        .world_to_instance_device = world_to_instance_device,
        .world_to_instance_host = world_to_instance_host,

        .tlas_handle = geometry_info.dst_acceleration_structure,
        .tlas_buffer = tlas_buffer,

        .tlas_update_scratch_buffer = update_scratch_buffer,
        .tlas_update_scratch_address = update_scratch_buffer.getAddress(vc),

        .geometry_count = total_geometry_count,
        .geometries = geometries,

        .alias_table = alias_table,
    };
}

// probably bad idea if you're changing many
// must recordRebuild to see changes
pub fn recordUpdateSingleTransform(self: *Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, instance_idx: u32, new_transform: Mat3x4) void {
    const offset = @sizeOf(vk.AccelerationStructureInstanceKHR) * instance_idx + @offsetOf(vk.AccelerationStructureInstanceKHR, "transform");
    const offset_inverse = @sizeOf(Mat3x4) * instance_idx;
    const size = @sizeOf(vk.TransformMatrixKHR);
    vc.device.cmdUpdateBuffer(command_buffer, self.instances_device.handle, offset, size, &new_transform);
    vc.device.cmdUpdateBuffer(command_buffer, self.world_to_instance_device.handle, offset_inverse, size, &new_transform.inverse_affine());
    const barriers = [_]vk.BufferMemoryBarrier2 {
        .{
            .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true, .shader_storage_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = self.instances_device.handle,
            .offset = offset,
            .size = size,
        },
        .{
            .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = self.world_to_instance_device.handle,
            .offset = offset_inverse,
            .size = size,
        },
    };
    vc.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        .buffer_memory_barrier_count = barriers.len,
        .p_buffer_memory_barriers = &barriers,
    });
}

// TODO: get it working
pub fn updateVisibility(self: *Self, instance_idx: u32, visible: bool) void {
    self.instances_host.data[instance_idx].instance_custom_index_and_mask.mask = if (visible) 0xFF else 0x00;
}

// probably bad idea if you're changing many
pub fn recordUpdateSingleMaterial(self: Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, geometry_idx: u32, new_material_idx: u32) void {
    const offset = @sizeOf(Geometry) * geometry_idx + @offsetOf(Geometry, "material");
    const size = @sizeOf(u32);
    vc.device.cmdUpdateBuffer(command_buffer, self.geometries.handle, offset, size, &new_material_idx);
    vc.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = @ptrCast(&vk.BufferMemoryBarrier2 {
            .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = self.geometries.handle,
            .offset = offset,
            .size = size,
        }),
    });
}

pub fn recordRebuild(self: *Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer) !void {
    const geometry = vk.AccelerationStructureGeometryKHR {
        .geometry_type = .instances_khr,
        .flags = .{ .opaque_bit_khr = true },
        .geometry = .{
            .instances = .{
                .array_of_pointers = vk.FALSE,
                .data = .{
                    .device_address = self.instances_address,
                }
            }
        },
    };

    var geometry_info = vk.AccelerationStructureBuildGeometryInfoKHR {
        .type = .top_level_khr,
        .flags = .{ .prefer_fast_trace_bit_khr = true, .allow_update_bit_khr = true },
        .mode = .update_khr,
        .src_acceleration_structure = self.tlas_handle,
        .dst_acceleration_structure = self.tlas_handle,
        .geometry_count = 1,
        .p_geometries = @ptrCast(&geometry),
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

    vc.device.cmdBuildAccelerationStructuresKHR(command_buffer, 1, @ptrCast(&geometry_info), @ptrCast(&build_info_ref));

    const barriers = [_]vk.MemoryBarrier2 {
        .{
            .src_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .src_access_mask = .{ .acceleration_structure_write_bit_khr = true },
            .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true },
        }
    };
    vc.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        .memory_barrier_count = barriers.len,
        .p_memory_barriers = &barriers,
    });
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.instances_device.destroy(vc);
    self.instances_host.destroy(vc);
    self.world_to_instance_device.destroy(vc);
    self.world_to_instance_host.destroy(vc);

    self.geometries.destroy(vc);

    self.alias_table.destroy(vc);

    self.tlas_update_scratch_buffer.destroy(vc);

    const blases_slice = self.blases.slice();
    const blases_handles = blases_slice.items(.handle);
    const blases_buffers = blases_slice.items(.buffer);

    for (0..self.blases.len) |i| {
        vc.device.destroyAccelerationStructureKHR(blases_handles[i], null);
        blases_buffers[i].destroy(vc);
    }
    self.blases.deinit(allocator);

    vc.device.destroyAccelerationStructureKHR(self.tlas_handle, null);
    self.tlas_buffer.destroy(vc);
}

fn getBuildSizesInfo(vc: *const VulkanContext, geometry_info: *const vk.AccelerationStructureBuildGeometryInfoKHR, max_primitive_count: [*]const u32) vk.AccelerationStructureBuildSizesInfoKHR {
    var size_info: vk.AccelerationStructureBuildSizesInfoKHR = undefined;
    size_info.s_type = .acceleration_structure_build_sizes_info_khr;
    size_info.p_next = null;
    vc.device.getAccelerationStructureBuildSizesKHR(.device_khr, geometry_info, max_primitive_count, &size_info);
    return size_info;
}
