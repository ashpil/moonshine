const std = @import("std");
const vk = @import("vulkan");
const Commands = @import("./Commands.zig");
const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const MeshManager = @import("./MeshManager.zig");
const Vertex = @import("../Object.zig").Vertex;
const utils = @import("./utils.zig");
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
// - a mesh group
//
// each mesh group (BLAS) has:
// - a list of meshes
//

pub const InstanceInfo = struct {
    transform: Mat3x4, // transform of this instance
    visible: bool = true, // whether this instance is visible
    mesh_group: u24, // index of mesh group used by this instance
    materials: []const u32, // indices of material used by each geometry in mesh group
    sampled_geometry: []const bool = &.{}, // whether each geometry in this instance is sampled, empty for no sampled
};

pub const Geometry = extern struct {
    mesh: u32, // idx of mesh that this geometry uses
    material: u32, // idx of material that this geometry uses
    sampled: bool, // whether this geometry is explicitly sampled for emitted light
};

pub const InstanceInfos = std.MultiArrayList(InstanceInfo);

pub const MeshGroup = struct {
    meshes: []const u32, // indices of meshes in this group
};

const BottomLevelAccels = std.MultiArrayList(struct {
    handle: vk.AccelerationStructureKHR,
    buffer: VkAllocator.DeviceBuffer,
});

blases: BottomLevelAccels,

instances_host: VkAllocator.HostBuffer(vk.AccelerationStructureInstanceKHR),
instances_device: VkAllocator.DeviceBuffer,
instances_address: vk.DeviceAddress,

// keep track of inverse transform -- non-inverse we can get from instances_device
world_to_instance: VkAllocator.DeviceBuffer,

// flat jagged array for geometries -- 
// use instanceCustomIndex + GeometryID() here to get geometry
geometries: VkAllocator.DeviceBuffer,
instance_idx_to_offset: []u24, // instance_idx_to_offset[instanceIdx] is instanceCustomIndex

// tlas stuff
tlas_handle: vk.AccelerationStructureKHR,
tlas_buffer: VkAllocator.DeviceBuffer,

tlas_update_scratch_buffer: VkAllocator.DeviceBuffer,
tlas_update_scratch_address: vk.DeviceAddress,

alias_table: VkAllocator.DeviceBuffer, // to sample lights

changed: bool,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, mesh_manager: MeshManager, instance_infos: InstanceInfos, mesh_groups: []const MeshGroup) !Self {
    // create a BLAS for each model
    // lots of temp memory allocations here
    const blases = blk: {
        const uncompacted_buffers = try allocator.alloc(VkAllocator.OwnedDeviceBuffer, mesh_groups.len);
        defer allocator.free(uncompacted_buffers);
        defer for (uncompacted_buffers) |buffer| buffer.destroy(vc);

        const uncompacted_blases = try allocator.alloc(vk.AccelerationStructureKHR, mesh_groups.len);
        defer allocator.free(uncompacted_blases);
        defer for (uncompacted_blases) |handle| vc.device.destroyAccelerationStructureKHR(handle, null);

        var build_geometry_infos = try allocator.alloc(vk.AccelerationStructureBuildGeometryInfoKHR, mesh_groups.len);
        defer allocator.free(build_geometry_infos);
        defer for (build_geometry_infos) |build_geometry_info| allocator.free(build_geometry_info.p_geometries.?[0..build_geometry_info.geometry_count]);

        const scratch_buffers = try allocator.alloc(VkAllocator.OwnedDeviceBuffer, mesh_groups.len);
        defer allocator.free(scratch_buffers);
        defer for (scratch_buffers) |scratch_buffer| scratch_buffer.destroy(vc);

        const build_infos = try allocator.alloc([*]vk.AccelerationStructureBuildRangeInfoKHR, mesh_groups.len);
        defer allocator.free(build_infos);
        defer for (build_infos, build_geometry_infos) |build_info, build_geometry_info| allocator.free(build_info[0..build_geometry_info.geometry_count]);

        for (mesh_groups, build_infos, build_geometry_infos, scratch_buffers, uncompacted_buffers, uncompacted_blases) |group, *build_info, *build_geometry_info, *scratch_buffer, *uncompacted_buffer, *uncompacted_blas| {
            const geometries = try allocator.alloc(vk.AccelerationStructureGeometryKHR, group.meshes.len);

            build_geometry_info.* = vk.AccelerationStructureBuildGeometryInfoKHR {
                .@"type" = .bottom_level_khr,
                .flags = .{ .prefer_fast_trace_bit_khr = true, .allow_compaction_bit_khr = true },
                .mode = .build_khr,
                .src_acceleration_structure = .null_handle,
                .dst_acceleration_structure = .null_handle,
                .geometry_count = @intCast(u32, geometries.len),
                .p_geometries = geometries.ptr,
                .pp_geometries = null,
                .scratch_data = undefined,
            };

            const primitive_counts = try allocator.alloc(u32, group.meshes.len);
            defer allocator.free(primitive_counts);

            build_info.* = (try allocator.alloc(vk.AccelerationStructureBuildRangeInfoKHR, group.meshes.len)).ptr;

            for (group.meshes, geometries, primitive_counts, 0..) |mesh_idx, *geometry, *primitive_count, j| {
                const mesh = mesh_manager.meshes.get(mesh_idx);

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
                            .max_vertex = @intCast(u32, mesh.vertex_count - 1),
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
                    .primitive_count = @intCast(u32, mesh.index_count),
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
                .create_flags = .{},
                .buffer = uncompacted_buffer.handle,
                .offset = 0,
                .size = size_info.acceleration_structure_size,
                .@"type" = .bottom_level_khr,
                .device_address = 0,
            }, null);
            errdefer vc.device.destroyAccelerationStructureKHR(build_geometry_info.dst_acceleration_structure, null);

            uncompacted_blas.* = build_geometry_info.dst_acceleration_structure;
        }

        const compactedSizes = try allocator.alloc(vk.DeviceSize, mesh_groups.len);
        defer allocator.free(compactedSizes);
        try commands.createAccelStructsAndGetCompactedSizes(vc, build_geometry_infos, build_infos, uncompacted_blases, compactedSizes);

        var blases = BottomLevelAccels {};
        try blases.ensureTotalCapacity(allocator, mesh_groups.len);
        errdefer blases.deinit(allocator);

        const copy_infos = try allocator.alloc(vk.CopyAccelerationStructureInfoKHR, mesh_groups.len);
        defer allocator.free(copy_infos);

        for (compactedSizes, copy_infos, uncompacted_blases) |compactedSize, *copy_info, uncompacted_blas| {
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

        break :blk blases;
    };

    // create instance info, tlas, and tlas state
    const instance_count = @intCast(u32, instance_infos.len);
    const instances_device = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(vk.AccelerationStructureInstanceKHR) * instance_count, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true, .storage_buffer_bit = true });
    errdefer instances_device.destroy(vc);

    const instances_host = try vk_allocator.createHostBuffer(vc, vk.AccelerationStructureInstanceKHR, instance_count, .{ .transfer_src_bit = true });
    errdefer instances_host.destroy(vc);

    const instance_transforms = instance_infos.items(.transform);
    const instance_visibles = instance_infos.items(.visible);
    const instance_mesh_groups = instance_infos.items(.mesh_group);
    const instance_materials = instance_infos.items(.materials);
    const instance_sampled_geometry = instance_infos.items(.sampled_geometry);

    const blas_handles = blases.items(.handle);

    var geometry_count: u24 = 0;
    const instance_idx_to_offset = blk: {
        const buffer = try allocator.alloc(u24, instance_count);
        errdefer allocator.free(buffer);

        for (instance_materials, buffer) |material_idxs, *val| {
            val.* = geometry_count;
            geometry_count += @intCast(u24, material_idxs.len);
        }

        break :blk buffer;
    };
    errdefer allocator.free(instance_idx_to_offset);

    // create geometries flat jagged array
    const geometries = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(Geometry) * geometry_count, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const buffer_host = try allocator.alloc(Geometry, geometry_count);
        defer allocator.free(buffer_host);

        var flat_idx: u32 = 0;
        for (instance_mesh_groups, 0..) |instance_mesh_group, i| {
            for (mesh_groups[instance_mesh_group].meshes, 0..) |mesh_idx, j| {
                buffer_host[flat_idx] = .{
                    .mesh = mesh_idx,
                    .material = instance_materials[i][j],
                    .sampled = if (instance_sampled_geometry[i].len != 0) instance_sampled_geometry[i][j] else false,
                };
                flat_idx += 1;
            }
        }

        try commands.uploadData(vc, vk_allocator, buffer.handle, std.mem.sliceAsBytes(buffer_host));

        break :blk buffer;
    };
    errdefer geometries.destroy(vc);

    for (instances_host.data, instance_transforms, instance_visibles, instance_mesh_groups, instance_idx_to_offset) |*instance, transform, visible, mesh_group, custom_index| {
        instance.* = .{
            .transform = vk.TransformMatrixKHR {
                .matrix = @bitCast([3][4]f32, transform),
            },
            .instance_custom_index_and_mask = .{
                .instance_custom_index = custom_index,
                .mask = if (visible) 0xFF else 0x00,
            },
            .instance_shader_binding_table_record_offset_and_flags = .{
                .instance_shader_binding_table_record_offset = 0,
                .flags = 0,
            },
            .acceleration_structure_reference = vc.device.getAccelerationStructureDeviceAddressKHR(&.{ 
                .acceleration_structure = blas_handles[mesh_group],
            }),
        };
    }

    try commands.startRecording(vc);
    commands.recordUploadBuffer(vk.AccelerationStructureInstanceKHR, vc, instances_device, instances_host);
    try commands.submitAndIdleUntilDone(vc);

    const instances_address = instances_device.getAddress(vc);

    const geometry = vk.AccelerationStructureGeometryKHR {
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

    const size_info = getBuildSizesInfo(vc, &geometry_info, utils.toPointerType(&instance_count));

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

    const world_to_instance = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(Mat3x4) * instance_count, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const inverses = try allocator.alloc(Mat3x4, instance_count);
        defer allocator.free(inverses);
        for (instance_transforms, inverses) |transform, *inverse| {
            inverse.* = transform.inverse_affine();
        }

        try commands.uploadData(vc, vk_allocator, buffer.handle, std.mem.sliceAsBytes(inverses));

        break :blk buffer;
    };
    errdefer world_to_instance.destroy(vc);

    const alias_table = blk: {

        const TableData = extern struct {
            instance: u32,
            geometry: u32,
            primitive: u32,
        };

        var weights = std.ArrayList(f32).init(allocator);
        defer weights.deinit();

        var table_data = std.ArrayList(TableData).init(allocator);
        defer table_data.deinit();

        for (instance_sampled_geometry, 0..) |sampled_geometry, i| {
            const transform = instance_transforms[i];
            for (sampled_geometry, 0..) |sampled, j| {
                if (!sampled) continue;

                const mesh_idx = mesh_groups[i].meshes[j];
                const positions = mesh_manager.meshes.items(.positions)[mesh_idx];
                const indices = mesh_manager.meshes.items(.indices)[mesh_idx];
                for (indices, 0..) |index, k| {
                    const p0 = transform.mul_point(positions[index.x]);
                    const p1 = transform.mul_point(positions[index.y]);
                    const p2 = transform.mul_point(positions[index.z]);
                    const area = p1.sub(p0).cross(p2.sub(p0)).length() / 2.0;
                    try weights.append(area);
                    try table_data.append(.{
                        .instance = @intCast(u32, i),
                        .geometry = @intCast(u32, j),
                        .primitive = @intCast(u32, k),
                    });
                }
            }
        }

        const AliasTableT = AliasTable(TableData);

        const table = try AliasTableT.create(allocator, weights.items, table_data.items);
        defer allocator.free(table.entries);

        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(AliasTableT.TableEntry) * (table.entries.len + 1), .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const bytes = std.mem.sliceAsBytes(table.entries);

        const staging_buffer = try vk_allocator.createHostBuffer(vc, u8, @intCast(u32, bytes.len) + @sizeOf(AliasTableT.TableEntry), .{ .transfer_src_bit = true });
        defer staging_buffer.destroy(vc);

        std.mem.copy(u8, staging_buffer.data, &std.mem.toBytes(@intCast(u32, table.entries.len)));
        std.mem.copy(u8, staging_buffer.data[@sizeOf(u32)..], &std.mem.toBytes(table.sum));
        std.mem.copy(u8, staging_buffer.data[@sizeOf(AliasTableT.TableEntry)..], bytes);

        try commands.startRecording(vc);
        commands.recordUploadBuffer(u8, vc, buffer, staging_buffer);
        try commands.submitAndIdleUntilDone(vc);

        break :blk buffer;
    };
    errdefer alias_table.destroy(vc);

    // build TLAS
    const build_info = vk.AccelerationStructureBuildRangeInfoKHR {
        .primitive_count = instance_count,
        .first_vertex = 0,
        .primitive_offset = 0,
        .transform_offset = 0,
    };
    try commands.createAccelStructs(vc, &.{ geometry_info }, &.{ utils.toPointerType(&build_info) });

    return Self {
        .blases = blases,

        .instances_host = instances_host,
        .instances_device = instances_device,
        .instances_address = instances_address,

        .world_to_instance = world_to_instance,

        .tlas_handle = geometry_info.dst_acceleration_structure,
        .tlas_buffer = tlas_buffer,

        .tlas_update_scratch_buffer = update_scratch_buffer,
        .tlas_update_scratch_address = update_scratch_buffer.getAddress(vc),

        .geometries = geometries,
        .instance_idx_to_offset = instance_idx_to_offset,

        .alias_table = alias_table,

        .changed = false,
    };
}

// TODO: these working with new transform buffers
pub fn updateTransform(self: *Self, instance_idx: u32, transform: Mat3x4) void {
    self.changed = true;

    self.instances_host.data[instance_idx].transform = vk.TransformMatrixKHR {
        .matrix = @bitCast([3][4]f32, transform),
    };
}

pub fn updateVisibility(self: *Self, instance_idx: u32, visible: bool) void {
    self.changed = true;
    
    self.instances_host.data[instance_idx].instance_custom_index_and_mask.mask = if (visible) 0xFF else 0x00;
}

pub fn updateSkin(self: *Self, instance_idx: u32, skin_idx: u12) void {
    _ = self;
    _ = instance_idx;
    _ = skin_idx;
    // TODO
    // self.changed = true;
    // var custom_index = @bitCast(CustomIndex, self.instances_host.data[instance_idx].instance_custom_index_and_mask.instance_custom_index);
    // custom_index.skin_idx = self.skin_idx_to_offset[skin_idx];
    // self.instances_host.data[instance_idx].instance_custom_index_and_mask.instance_custom_index = @bitCast(u24, custom_index);
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
                        .device_address = self.instances_address,
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
            .primitive_count = @intCast(u32, self.instances_host.data.len),
            .first_vertex = 0,
            .primitive_offset = 0,
            .transform_offset = 0,
        };

        const build_info_ref = utils.toPointerType(&build_info);

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
    self.instances_device.destroy(vc);
    self.instances_host.destroy(vc);
    self.world_to_instance.destroy(vc);

    self.geometries.destroy(vc);

    self.alias_table.destroy(vc);

    allocator.free(self.instance_idx_to_offset);

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

fn getBuildSizesInfo(vc: *const VulkanContext, geometry_info: *const vk.AccelerationStructureBuildGeometryInfoKHR, max_primitive_count: [*]const u32) vk.AccelerationStructureBuildSizesInfoKHR {
    var size_info: vk.AccelerationStructureBuildSizesInfoKHR = undefined;
    size_info.s_type = .acceleration_structure_build_sizes_info_khr;
    size_info.p_next = null;
    vc.device.getAccelerationStructureBuildSizesKHR(.device_khr, geometry_info, max_primitive_count, &size_info);
    return size_info;
}
