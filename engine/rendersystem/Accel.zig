const std = @import("std");
const vk = @import("vulkan");
const Commands = @import("./Commands.zig");
const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const MeshManager = @import("./MeshManager.zig");
const Vertex = @import("../Object.zig").Vertex;
const utils = @import("./utils.zig");

const vector = @import("../vector.zig");
const Mat3x4 = vector.Mat3x4(f32);
const F32x3 = vector.Vec3(f32);

// "accel" perhaps the wrong name for this struct at this point, maybe "heirarchy" would be better
// the acceleration structure is the primary scene heirarchy, and controls
// how all the meshes and materials fit together
// 
// an acceleration structure has:
// - a list of instances
//
// each instance has:
// - a transform
// - a visible flag
// - a model
// - a skin
//
// each model has:
// - a list of meshes
//
// each skin has:
// - a list of materials
//
// a BLAS is made from each model
//

pub const Instance = struct {
    transform: Mat3x4, // transform of this instance
    visible: bool = true, // whether this instance is visible
    model_idx: u12, // index of model used by this instance
    skin_idx: u12, // index of skin used by this instance
};
pub const Instances = std.MultiArrayList(Instance);

pub const Model = struct {
    mesh_idxs: []const u32,
};

pub const Skin = struct {
    material_idxs: []const u32,
};

const BottomLevelAccels = std.MultiArrayList(struct {
    handle: vk.AccelerationStructureKHR,
    buffer: VkAllocator.DeviceBuffer,
});

blases: BottomLevelAccels,

//
// TODO: when I created this I really wanted to have this symmetry between materials/meshes in a given instance,
// but the more I think about it, it becomes not quite right, as meshes are static for an instance, but materials 
// are not
//

instances: VkAllocator.HostBuffer(vk.AccelerationStructureInstanceKHR),
instances_address: vk.DeviceAddress,

// two buffers, same idea for geo and material
// use instanceCustomIndex + GeometryID() idx into here to get actual material/geo
mesh_idxs: VkAllocator.DeviceBuffer,
material_idxs: VkAllocator.DeviceBuffer,

// need these to construct above
model_idx_to_offset: []u12, // not sure if this actually ever needs to be used
skin_idx_to_offset: []u12,

// tlas stuff
tlas_handle: vk.AccelerationStructureKHR,
tlas_buffer: VkAllocator.DeviceBuffer,

tlas_update_scratch_buffer: VkAllocator.DeviceBuffer,
tlas_update_scratch_address: vk.DeviceAddress,

// keep track of transforms
instance_to_world: VkAllocator.DeviceBuffer,
world_to_instance: VkAllocator.DeviceBuffer, // inverse of above

changed: bool,

const Self = @This();

const CustomIndex = packed struct {
    model_idx: u12,
    skin_idx: u12,
};

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, mesh_manager: MeshManager, instances: Instances, models: []const Model, skins: []const Skin) !Self {
    // create a BLAS for each model
    // lots of temp memory allocations here
    const blases = blk: {
        const geometry_count = models.len;

        const uncompacted_buffers = try allocator.alloc(VkAllocator.OwnedDeviceBuffer, models.len);
        defer allocator.free(uncompacted_buffers);
        defer for (uncompacted_buffers) |buffer| buffer.destroy(vc);

        const uncompacted_blases = try allocator.alloc(vk.AccelerationStructureKHR, models.len);
        defer allocator.free(uncompacted_blases);
        defer for (uncompacted_blases) |handle| vc.device.destroyAccelerationStructureKHR(handle, null);

        var build_geometry_infos = try allocator.alloc(vk.AccelerationStructureBuildGeometryInfoKHR, models.len);
        defer allocator.free(build_geometry_infos);
        defer for (build_geometry_infos) |build_geometry_info| allocator.free(build_geometry_info.p_geometries.?[0..build_geometry_info.geometry_count]);

        const scratch_buffers = try allocator.alloc(VkAllocator.OwnedDeviceBuffer, models.len);
        defer allocator.free(scratch_buffers);
        defer for (scratch_buffers) |scratch_buffer| scratch_buffer.destroy(vc);

        const build_infos = try allocator.alloc([*]vk.AccelerationStructureBuildRangeInfoKHR, models.len);
        defer allocator.free(build_infos);
        defer for (build_infos) |build_info, i| allocator.free(build_info[0..build_geometry_infos[i].geometry_count]);

        for (models) |model, i| {
            const geometries = try allocator.alloc(vk.AccelerationStructureGeometryKHR, model.mesh_idxs.len);

            build_geometry_infos[i] = vk.AccelerationStructureBuildGeometryInfoKHR {
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

            const primitive_counts = try allocator.alloc(u32, model.mesh_idxs.len);
            defer allocator.free(primitive_counts);

            build_infos[i] = (try allocator.alloc(vk.AccelerationStructureBuildRangeInfoKHR, model.mesh_idxs.len)).ptr;

            for (model.mesh_idxs) |mesh_idx, j| {
                const mesh = mesh_manager.meshes.get(mesh_idx);

                geometries[j] = vk.AccelerationStructureGeometryKHR {
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

                build_infos[i][j] =  vk.AccelerationStructureBuildRangeInfoKHR {
                    .primitive_count = @intCast(u32, mesh.index_count),
                    .primitive_offset = 0,
                    .transform_offset = 0,
                    .first_vertex = 0,
                };
                primitive_counts[j] = build_infos[i][j].primitive_count;
            }

            const size_info = getBuildSizesInfo(vc, &build_geometry_infos[i], primitive_counts.ptr);

            scratch_buffers[i] = try vk_allocator.createOwnedDeviceBuffer(vc, size_info.build_scratch_size, .{ .shader_device_address_bit = true, .storage_buffer_bit = true });
            errdefer scratch_buffers[i].destroy(vc);
            build_geometry_infos[i].scratch_data.device_address = scratch_buffers[i].getAddress(vc);

            uncompacted_buffers[i] = try vk_allocator.createOwnedDeviceBuffer(vc, size_info.acceleration_structure_size, .{ .acceleration_structure_storage_bit_khr = true });
            errdefer uncompacted_buffers[i].destroy(vc);

            build_geometry_infos[i].dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(&.{
                .create_flags = .{},
                .buffer = uncompacted_buffers[i].handle,
                .offset = 0,
                .size = size_info.acceleration_structure_size,
                .@"type" = .bottom_level_khr,
                .device_address = 0,
            }, null);
            errdefer vc.device.destroyAccelerationStructureKHR(build_geometry_infos[i].dst_acceleration_structure, null);

            uncompacted_blases[i] = build_geometry_infos[i].dst_acceleration_structure;
        }

        const compactedSizes = try allocator.alloc(vk.DeviceSize, geometry_count);
        defer allocator.free(compactedSizes);
        try commands.createAccelStructsAndGetCompactedSizes(vc, build_geometry_infos, build_infos, uncompacted_blases, compactedSizes);

        var blases = BottomLevelAccels {};
        try blases.ensureTotalCapacity(allocator, geometry_count);
        errdefer blases.deinit(allocator);

        const copy_infos = try allocator.alloc(vk.CopyAccelerationStructureInfoKHR, geometry_count);
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
                .src = uncompacted_blases[i],
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
    const instance_count = @intCast(u32, instances.len);
    const vk_instances = try vk_allocator.createHostBuffer(vc, vk.AccelerationStructureInstanceKHR, instance_count, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
    errdefer vk_instances.destroy(vc);

    const instance_transforms = instances.items(.transform);
    const instance_visibles = instances.items(.visible);
    const instance_models = instances.items(.model_idx);
    const instance_skins = instances.items(.skin_idx);
    
    const blas_handles = blases.items(.handle);

    for (vk_instances.data) |*instance, i| {
        const custom_index = @bitCast(u24, CustomIndex {
            .model_idx = instance_models[i],
            .skin_idx = instance_skins[i],
        });
        instance.* = .{
            .transform = vk.TransformMatrixKHR {
                .matrix = @bitCast([3][4]f32, instance_transforms[i]),
            },
            .instance_custom_index_and_mask = .{
                .instance_custom_index = custom_index,
                .mask = if (instance_visibles[i]) 0xFF else 0x00,
            },
            .instance_shader_binding_table_record_offset_and_flags = .{
                .instance_shader_binding_table_record_offset = 0,
                .flags = 0,
            },
            .acceleration_structure_reference = vc.device.getAccelerationStructureDeviceAddressKHR(&.{ 
                .acceleration_structure = blas_handles[instance_models[i]],
            }),
        };
    }

    const vk_instances_address = vk_instances.getAddress(vc);

    const geometry = vk.AccelerationStructureGeometryKHR {
        .geometry_type = .instances_khr,
        .flags = .{ .opaque_bit_khr = true },
        .geometry = .{
            .instances = .{
                .array_of_pointers = vk.FALSE,
                .data = .{
                    .device_address = vk_instances_address,
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

    var offset_so_far: u12 = undefined;
    const model_idx_to_offset = blk: {
        const buffer = try allocator.alloc(u12, models.len);
        errdefer allocator.free(buffer);
        offset_so_far = 0;
        for (models) |model, i| {
            buffer[i] = offset_so_far;
            offset_so_far += @intCast(u12, model.mesh_idxs.len);
        }

        break :blk buffer;
    };
    errdefer allocator.free(model_idx_to_offset);

    // flatten out models jagged array
    const mesh_idxs = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(u32) * offset_so_far, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const buffer_host = try allocator.alloc(u32, offset_so_far);
        defer allocator.free(buffer_host);
        var flat_idx: u32 = 0;
        for (models) |model| {
            for (model.mesh_idxs) |mesh_idx| {
                buffer_host[flat_idx] = mesh_idx;
                flat_idx += 1;
            }
        }

        try commands.uploadData(vc, vk_allocator, buffer.handle, std.mem.sliceAsBytes(buffer_host));

        break :blk buffer;
    };
    errdefer mesh_idxs.destroy(vc);

    const skin_idx_to_offset = blk: {
        const buffer = try allocator.alloc(u12, skins.len);
        errdefer allocator.free(buffer);
        offset_so_far = 0;
        for (skins) |skin, i| {
            buffer[i] = offset_so_far;
            offset_so_far += @intCast(u12, skin.material_idxs.len);
        }

        break :blk buffer;
    };
    errdefer allocator.free(skin_idx_to_offset);

    // flatten out skins jagged array
    const material_idxs = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(u32) * offset_so_far, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const buffer_host = try allocator.alloc(u32, offset_so_far);
        defer allocator.free(buffer_host);
        var flat_idx: u32 = 0;
        for (skins) |skin| {
            for (skin.material_idxs) |material_idx| {
                buffer_host[flat_idx] = material_idx;
                flat_idx += 1;
            }
        }

        try commands.uploadData(vc, vk_allocator, buffer.handle, std.mem.sliceAsBytes(buffer_host));

        break :blk buffer;
    };
    errdefer material_idxs.destroy(vc);


    // create transform stuff
    const instance_to_world = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(Mat3x4) * instance_count, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        try commands.uploadData(vc, vk_allocator, buffer.handle, std.mem.sliceAsBytes(instance_transforms));

        break :blk buffer;
    };
    errdefer instance_to_world.destroy(vc);

    const world_to_instance = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(Mat3x4) * instance_count, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const inverses = try allocator.alloc(Mat3x4, instance_count);
        defer allocator.free(inverses);
        for (instance_transforms) |transform, i| {
            inverses[i] = transform.inverse_affine();
        }

        try commands.uploadData(vc, vk_allocator, buffer.handle, std.mem.sliceAsBytes(inverses));

        break :blk buffer;
    };
    errdefer world_to_instance.destroy(vc);

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

        .instances = vk_instances,
        .instances_address = vk_instances_address,

        .tlas_handle = geometry_info.dst_acceleration_structure,
        .tlas_buffer = tlas_buffer,

        .tlas_update_scratch_buffer = update_scratch_buffer,
        .tlas_update_scratch_address = update_scratch_buffer.getAddress(vc),

        .material_idxs = material_idxs,
        .mesh_idxs = mesh_idxs,

        .model_idx_to_offset = model_idx_to_offset,
        .skin_idx_to_offset = skin_idx_to_offset,

        .instance_to_world = instance_to_world,
        .world_to_instance = world_to_instance,

        .changed = false,
    };
}

// TODO: these working with new transform buffers
pub fn updateTransform(self: *Self, instance_idx: u32, transform: Mat3x4) void {
    self.changed = true;

    self.instances.data[instance_idx].transform = vk.TransformMatrixKHR {
        .matrix = @bitCast([3][4]f32, transform),
    };
}

pub fn updateVisibility(self: *Self, instance_idx: u32, visible: bool) void {
    self.changed = true;
    
    self.instances.data[instance_idx].instance_custom_index_and_mask.mask = if (visible) 0xFF else 0x00;
}

// hmm technically current system requires accel rebuild on simply skin change, which isn't actually required
pub fn updateSkin(self: *Self, instance_idx: u32, skin_idx: u12) void {
    self.changed = true;
    
    var custom_index = @bitCast(CustomIndex, self.instances.data[instance_idx].instance_custom_index_and_mask.instance_custom_index);
    custom_index.skin_idx = self.skin_idx_to_offset[skin_idx];
    self.instances.data[instance_idx].instance_custom_index_and_mask.instance_custom_index = @bitCast(u24, custom_index);
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
            .primitive_count = @intCast(u32, self.instances.data.len),
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
    self.instances.destroy(vc);

    self.mesh_idxs.destroy(vc);
    self.material_idxs.destroy(vc);

    self.instance_to_world.destroy(vc);
    self.world_to_instance.destroy(vc);

    allocator.free(self.model_idx_to_offset);
    allocator.free(self.skin_idx_to_offset);

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
