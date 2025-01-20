const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const Image = core.Image;
const vk_helpers = core.vk_helpers;

const MeshManager = @import("./MeshManager.zig");
const MaterialManager = @import("./MaterialManager.zig");

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

pub const Instance = struct {
    transform: Mat3x4, // transform of this instance
    visible: bool = true, // whether this instance is visible
    thin: bool = true,
    geometries: []const Geometry, // geometries in this instance
};

pub const Geometry = extern struct {
    mesh: u32, // idx of mesh that this geometry uses
    material: u32, // idx of material that this geometry uses
};

const BottomLevelAccels = std.MultiArrayList(struct {
    handle: vk.AccelerationStructureKHR,
    buffer: core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }),
});

const TrianglePowerPipeline = engine.core.pipeline.Pipeline(.{ .shader_path = "hrtsystem/mesh_sampling/power.hlsl",
    .PushConstants = extern struct {
        instance_index: u32,
        geometry_index: u32,
        triangle_count: u32,
    },
    .PushSetBindings = struct {
        instances: vk.Buffer,
        world_to_instances: vk.Buffer,
        meshes: vk.Buffer,
        geometries: vk.Buffer,
        material_values: vk.Buffer,
        emissive_triangle_count: vk.Buffer,
        dst_power: engine.core.pipeline.StorageImage,
        dst_triangle_metadata: vk.Buffer,
    },
    .additional_descriptor_layout_count = 1,
});

const TrianglePowerFoldPipeline = engine.core.pipeline.Pipeline(.{ .shader_path = "hrtsystem/mesh_sampling/fold.hlsl",
    .PushSetBindings = struct {
        src_mip: engine.core.pipeline.SampledImage,
        dst_mip: engine.core.pipeline.StorageImage,
        instances: vk.Buffer,
        geometry_to_triangle_power_offset: vk.Buffer,
        emissive_triangle_count: vk.Buffer,
    },
    .PushConstants = extern struct {
        instance_index: u32,
        geometry_index: u32,
        triangle_count: u32,
    },
});

const TriangleMetadata = extern struct {
    instance_index: u32,
    geometry_index: u32,
};

triangle_power_pipeline: TrianglePowerPipeline,
triangle_power_fold_pipeline: TrianglePowerFoldPipeline,
// TODO: this needs to be 2D and possibly aliased, or just a buffer rather than an image
triangle_powers_meta: core.mem.DeviceBuffer(TriangleMetadata, .{ .storage_buffer_bit = true }),
triangle_powers: Image,
triangle_powers_mips: [std.math.log2(max_emissive_triangles) + 1]vk.ImageView,
geometry_to_triangle_power_offset: core.mem.DeviceBuffer(u32, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }) = .{},
emissive_triangle_count: core.mem.DeviceBuffer(u32, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }), // size 1

blases: BottomLevelAccels = .{},

instance_count: u32 = 0,
instances_device: core.mem.DeviceBuffer(vk.AccelerationStructureInstanceKHR, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true, .storage_buffer_bit = true }),
instances_host: core.mem.UploadBuffer(vk.AccelerationStructureInstanceKHR),
instances_address: vk.DeviceAddress,

// keep track of inverse transform -- non-inverse we can get from instances_device
// transforms provided by shader only in hit/intersection shaders but we need them
// in raygen
// ray queries provide them in any shader which would be a benefit of using them
world_to_instance_device: core.mem.DeviceBuffer(Mat3x4, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }),
world_to_instance_host: core.mem.UploadBuffer(Mat3x4),

// flat jagged array for geometries --
// use instanceCustomIndex + GeometryID() here to get geometry
geometry_count: u24 = 0,
geometries: core.mem.DeviceBuffer(Geometry, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }),

// tlas stuff
tlas_handle: vk.AccelerationStructureKHR = .null_handle,
tlas_buffer: core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }) = .{},

tlas_update_scratch_buffer: core.mem.DeviceBuffer(u8, .{ .storage_buffer_bit = true, .shader_device_address_bit = true }) = .{},
tlas_update_scratch_address: vk.DeviceAddress = 0,

const Self = @This();

// TODO: resizable buffers
const max_instances = std.math.powi(u32, 2, 12) catch unreachable;
const max_geometries = std.math.powi(u32, 2, 12) catch unreachable;
const max_emissive_triangles = std.math.powi(u32, 2, 15) catch unreachable;

// lots of temp memory allocations here
// encoder must be in recording state
// returns scratch buffers that must be kept alive until command is completed
fn makeBlases(vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, mesh_manager: MeshManager, geometries: []const []const Geometry, blases: *BottomLevelAccels) !void {
    const build_geometry_infos = try allocator.alloc(vk.AccelerationStructureBuildGeometryInfoKHR, geometries.len);
    defer allocator.free(build_geometry_infos);
    defer for (build_geometry_infos) |build_geometry_info| allocator.free(build_geometry_info.p_geometries.?[0..build_geometry_info.geometry_count]);

    const build_infos = try allocator.alloc([*]vk.AccelerationStructureBuildRangeInfoKHR, geometries.len);
    defer allocator.free(build_infos);
    defer for (build_infos, build_geometry_infos) |build_info, build_geometry_info| allocator.free(build_info[0..build_geometry_info.geometry_count]);

    try blases.ensureUnusedCapacity(allocator, geometries.len);

    // place these barriers ahead of the for loop before so that if the vulkan implementaiton
    // treats all barriers as global, we won't serialize BLAS builds.
    // though maybe it should be somewhere else completely...
    for (geometries) |geometry_list| {
        for (geometry_list) |geometry| {
            const mesh = mesh_manager.meshes.get(geometry.mesh);
            encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
                Encoder.BufferBarrier {
                    .src_stage_mask = .{ .all_transfer_bit = true },
                    .src_access_mask = .{ .transfer_write_bit = true },
                    .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
                    .dst_access_mask = .{ .memory_read_bit = true },
                    .buffer = mesh.index_buffer.handle,
                },
                Encoder.BufferBarrier {
                    .src_stage_mask = .{ .all_transfer_bit = true },
                    .src_access_mask = .{ .transfer_write_bit = true },
                    .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
                    .dst_access_mask = .{ .memory_read_bit = true },
                    .buffer = mesh.position_buffer.handle,
                },
            });
        }
    }

    for (geometries, build_infos, build_geometry_infos) |list, *build_info, *build_geometry_info| {
        const vk_geometries = try allocator.alloc(vk.AccelerationStructureGeometryKHR, list.len);

        build_geometry_info.* = vk.AccelerationStructureBuildGeometryInfoKHR {
            .type = .bottom_level_khr,
            .flags = .{ .prefer_fast_trace_bit_khr = true },
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
                        .index_type = if (mesh.index_count != 0) .uint32 else .none_khr,
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
                .primitive_count = @intCast(if (mesh.index_count != 0) mesh.index_count else @divExact(mesh.vertex_count, 3)),
                .primitive_offset = 0,
                .transform_offset = 0,
                .first_vertex = 0,
            };
            primitive_count.* = build_info.*[j].primitive_count;
        }

        const size_info = getBuildSizesInfo(vc, build_geometry_info, primitive_counts.ptr);

        const scratch_buffer = try core.mem.DeviceBuffer(u8, .{ .storage_buffer_bit = true, .shader_device_address_bit = true }).create(vc, size_info.build_scratch_size, "blas scratch buffer");
        try encoder.attachResource(scratch_buffer);
        build_geometry_info.scratch_data.device_address = scratch_buffer.getAddress(vc);

        const buffer = try core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }).create(vc, size_info.acceleration_structure_size, "blas buffer");
        errdefer buffer.destroy(vc);

        build_geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(&.{
            .buffer = buffer.handle,
            .offset = 0,
            .size = size_info.acceleration_structure_size,
            .type = .bottom_level_khr,
        }, null);
        errdefer vc.device.destroyAccelerationStructureKHR(build_geometry_info.dst_acceleration_structure, null);

        blases.appendAssumeCapacity(.{
            .handle = build_geometry_info.dst_acceleration_structure,
            .buffer = buffer,
        });
    }

    encoder.buildAccelerationStructures(build_geometry_infos, build_infos);
}

pub fn createEmpty(vc: *const VulkanContext, allocator: std.mem.Allocator, texture_descriptor_layout: MaterialManager.TextureManager.DescriptorLayout, encoder: *Encoder) !Self {
    var triangle_power_pipeline = try TrianglePowerPipeline.create(vc, allocator, .{}, .{}, .{ texture_descriptor_layout.handle });
    errdefer triangle_power_pipeline.destroy(vc);

    var triangle_power_fold_pipeline = try TrianglePowerFoldPipeline.create(vc, allocator, .{}, .{}, .{});
    errdefer triangle_power_fold_pipeline.destroy(vc);

    const triangle_powers_meta = try core.mem.DeviceBuffer(TriangleMetadata, .{ .storage_buffer_bit = true }).create(vc, max_emissive_triangles, "triangle powers meta");
    errdefer triangle_powers_meta.destroy(vc);

    const emissive_triangle_count = try core.mem.DeviceBuffer(u32, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, 1, "emissive triangle count");
    errdefer emissive_triangle_count.destroy(vc);

    const triangle_powers = try Image.create(vc, vk.Extent2D { .width = max_emissive_triangles, .height = 1 }, .{ .storage_bit = true, .sampled_bit = true, .transfer_dst_bit = true }, .r32_sfloat, true, "triangle powers");
    errdefer triangle_powers.destroy(vc);

    var triangle_powers_mips: [std.math.log2(max_emissive_triangles) + 1]vk.ImageView = undefined;
    inline for (&triangle_powers_mips, 0..) |*view, level_index| {
        view.* = try vc.device.createImageView(&vk.ImageViewCreateInfo {
            .flags = .{},
            .image = triangle_powers.handle,
            .view_type = vk.ImageViewType.@"1d",
            .format = .r32_sfloat,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = @intCast(level_index),
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
        }, null);
        try vk_helpers.setDebugName(vc.device, view.*, std.fmt.comptimePrint("triangle powers view {}", .{ level_index }));
    }

    const geometries = try core.mem.DeviceBuffer(Geometry, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, max_geometries, "geometries");
    errdefer geometries.destroy(vc);
    const geometry_to_triangle_power_offset = try core.mem.DeviceBuffer(u32, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, max_geometries, "geometry to triangle power offset");
    errdefer geometry_to_triangle_power_offset.destroy(vc);

    const instances_device = try core.mem.DeviceBuffer(vk.AccelerationStructureInstanceKHR, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true, .storage_buffer_bit = true }).create(vc, max_instances, "instances");
    errdefer instances_device.destroy(vc);
    const instances_host = try core.mem.UploadBuffer(vk.AccelerationStructureInstanceKHR).create(vc, max_instances, "instances");
    errdefer instances_host.destroy(vc);
    const instances_address = instances_device.getAddress(vc);

    const world_to_instance_device = try core.mem.DeviceBuffer(Mat3x4, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, max_instances, "world to instances");
    errdefer world_to_instance_device.destroy(vc);
    const world_to_instance_host = try core.mem.UploadBuffer(Mat3x4).create(vc, max_instances, "world to instances");
    errdefer world_to_instance_host.destroy(vc);

    encoder.buffer.pipelineBarrier2(&vk.DependencyInfo {
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[1]vk.ImageMemoryBarrier2 {
            .{
                .dst_stage_mask = .{ .clear_bit = true },
                .dst_access_mask = .{ .transfer_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = triangle_powers.handle,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = vk.REMAINING_MIP_LEVELS,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            }
        },
    });
    encoder.clearColorImage(triangle_powers.handle, .transfer_dst_optimal, vk.ClearColorValue { .float_32 = .{ 0, 0, 0, 0 }});
    encoder.fillBuffer(emissive_triangle_count.handle, 1, @as(u32, 0));
    encoder.fillBuffer(geometry_to_triangle_power_offset.handle, max_geometries, @as(u32, std.math.maxInt(u32)));
    encoder.buffer.pipelineBarrier2(&vk.DependencyInfo {
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[1]vk.ImageMemoryBarrier2 {
            .{
                .src_stage_mask = .{ .clear_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .old_layout = .transfer_dst_optimal,
                .new_layout = .shader_read_only_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = triangle_powers.handle,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = vk.REMAINING_MIP_LEVELS,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            }
        },
    });

    return Self {
        .triangle_power_pipeline = triangle_power_pipeline,
        .triangle_power_fold_pipeline = triangle_power_fold_pipeline,
        .triangle_powers_meta = triangle_powers_meta,
        .triangle_powers = triangle_powers,
        .triangle_powers_mips = triangle_powers_mips,
        .emissive_triangle_count = emissive_triangle_count,
        .geometries = geometries,
        .geometry_to_triangle_power_offset = geometry_to_triangle_power_offset,
        .instances_device = instances_device,
        .instances_host = instances_host,
        .instances_address = instances_address,
        .world_to_instance_device = world_to_instance_device,
        .world_to_instance_host = world_to_instance_host,
    };
}

// accel must not be in use
pub const Handle = u32;
pub fn uploadInstance(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, mesh_manager: MeshManager, material_manager: MaterialManager, instance: Instance) !Handle {
    std.debug.assert(self.geometry_count + instance.geometries.len <= max_geometries);
    std.debug.assert(self.instance_count < max_instances);

    try makeBlases(vc, allocator, encoder, mesh_manager, &.{ instance.geometries }, &self.blases);

    // update geometries flat jagged array
    self.geometries.updateFrom(encoder, self.geometry_count, instance.geometries);

    // upload instance
    {
        const vk_instance = vk.AccelerationStructureInstanceKHR {
            .transform = vk.TransformMatrixKHR {
                .matrix = @bitCast(instance.transform),
            },
            .instance_custom_index_and_mask = .{
                .instance_custom_index = self.geometry_count,
                .mask = if (instance.visible) if (instance.thin) 0b10000000 else 0xFF else 0x00,
            },
            .instance_shader_binding_table_record_offset_and_flags = .{
                .instance_shader_binding_table_record_offset = 0,
                .flags = 0,
            },
            .acceleration_structure_reference = vc.device.getAccelerationStructureDeviceAddressKHR(&.{
                .acceleration_structure = self.blases.items(.handle)[self.blases.len - 1],
            }),
        };

        self.instances_host.hostSlice()[self.instance_count] = vk_instance;

        self.instances_device.updateFrom(encoder, self.instance_count, &.{ vk_instance }); // TODO: can copy
    }

    // upload world_to_instance matrix
    {
        self.world_to_instance_host.hostSlice()[self.instance_count] = instance.transform.inverseAffine();
        self.world_to_instance_device.updateFrom(encoder, self.instance_count, &.{ instance.transform.inverseAffine() }); // TODO: can copy
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

    const scratch_buffer = try core.mem.DeviceBuffer(u8, .{ .storage_buffer_bit = true, .shader_device_address_bit = true }).create(vc, size_info.build_scratch_size, "tlas scratch buffer");
    try encoder.attachResource(scratch_buffer);

    try encoder.attachResource(self.tlas_buffer); // might still be used if this function was called in a loop. TODO: do not needlessly rebuild TLAS in this situation
    self.tlas_buffer = try core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }).create(vc, size_info.acceleration_structure_size, "tlas buffer");

    try encoder.attachResource(self.tlas_handle); // might still be used if this function was called in a loop. TODO: do not needlessly rebuild TLAS in this situation
    geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(&.{
        .buffer = self.tlas_buffer.handle,
        .offset = 0,
        .size = size_info.acceleration_structure_size,
        .type = .top_level_khr,
    }, null);
    self.tlas_handle = geometry_info.dst_acceleration_structure;

    geometry_info.scratch_data.device_address = scratch_buffer.getAddress(vc);

    self.tlas_update_scratch_buffer.destroy(vc);
    self.tlas_update_scratch_buffer = try core.mem.DeviceBuffer(u8, .{ .storage_buffer_bit = true, .shader_device_address_bit = true }).create(vc, size_info.update_scratch_size, "tlas update scratch buffer");
    self.tlas_update_scratch_address = self.tlas_update_scratch_buffer.getAddress(vc);

    encoder.buildAccelerationStructures(&.{ geometry_info }, &[_][*]const vk.AccelerationStructureBuildRangeInfoKHR{ @ptrCast(&vk.AccelerationStructureBuildRangeInfoKHR {
        .primitive_count = @intCast(self.instance_count),
        .first_vertex = 0,
        .primitive_offset = 0,
        .transform_offset = 0,
    })});

    encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
            .buffer = self.instances_device.handle,
        },
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
            .buffer = self.geometries.handle,
        },
    });
    for (instance.geometries, 0..) |geometry, i| {
        self.recordUpdatePower(encoder, mesh_manager, material_manager, @intCast(self.instance_count - 1), @intCast(i), geometry.mesh);
    }

    self.geometry_count += @intCast(instance.geometries.len);

    return @intCast(self.instance_count - 1);
}

pub fn recordUpdatePower(self: *Self, encoder: *Encoder, mesh_manager: MeshManager, material_manager: MaterialManager, instance_index: u32, geometry_index: u32, mesh_index: u32) void {
    const mesh = mesh_manager.meshes.get(mesh_index);
    const primitive_count = if (mesh.index_count != 0) mesh.index_count else @divExact(mesh.vertex_count, 3);

    // this mesh is too big to importance sample...
    // it may still emit without importance sampling, though
    //
    // TODO: technically this should check that the that total (in the whole scene) emissive triangle count is less than
    // the maximum number of emissive triangles, but we don't have access to that info on the host.
    // probably we will just get a GPU crash instead :(
    if (primitive_count > max_emissive_triangles) return;

    encoder.barrier(&[_]Encoder.ImageBarrier {
        Encoder.ImageBarrier {
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = .{ .shader_read_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_write_bit = true },
            .old_layout = .shader_read_only_optimal,
            .new_layout = .general,
            .image = self.triangle_powers.handle,
            .base_mip_level = 0,
            .level_count = 1,
        }
    }, &.{});

    self.triangle_power_pipeline.recordBindPipeline(encoder.buffer);
    self.triangle_power_pipeline.recordBindAdditionalDescriptorSets(encoder.buffer, .{ material_manager.textures.descriptor_set });
    self.triangle_power_pipeline.recordPushDescriptors(encoder.buffer, .{
        .instances = self.instances_device.handle,
        .world_to_instances = self.world_to_instance_device.handle,
        .meshes = mesh_manager.addresses_buffer.handle,
        .geometries = self.geometries.handle,
        .material_values = material_manager.materials.handle,
        .emissive_triangle_count = self.emissive_triangle_count.handle,
        .dst_power = .{ .view = self.triangle_powers_mips[0] },
        .dst_triangle_metadata = self.triangle_powers_meta.handle,
    });
    self.triangle_power_pipeline.recordPushConstants(encoder.buffer, .{
        .instance_index = instance_index,
        .geometry_index = geometry_index,
        .triangle_count = primitive_count,
    });
    const shader_local_size = 32; // must be kept in sync with shader -- looks like HLSL doesn't support setting this via spec constants
    const dispatch_size = std.math.divCeil(u32, primitive_count, shader_local_size) catch unreachable;
    self.triangle_power_pipeline.recordDispatch(encoder.buffer, .{ .width = dispatch_size, .height = 1, .depth = 1 });
    self.triangle_power_fold_pipeline.recordBindPipeline(encoder.buffer);

    for (1..self.triangle_powers_mips.len) |dst_mip_level| {
        encoder.barrier(&[_]Encoder.ImageBarrier {
            Encoder.ImageBarrier {
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .old_layout = .general,
                .new_layout = .shader_read_only_optimal,
                .image = self.triangle_powers.handle,
                .base_mip_level = @intCast(dst_mip_level - 1),
                .level_count = 1,
            },
            Encoder.ImageBarrier {
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .shader_read_only_optimal,
                .new_layout = .general,
                .image = self.triangle_powers.handle,
                .base_mip_level = @intCast(dst_mip_level),
                .level_count = 1,
            }
        }, &.{});
        self.triangle_power_fold_pipeline.recordPushDescriptors(encoder.buffer, .{
            .src_mip = .{ .view = self.triangle_powers_mips[dst_mip_level - 1] },
            .dst_mip = .{ .view = self.triangle_powers_mips[dst_mip_level] },
            .instances = self.instances_device.handle,
            .geometry_to_triangle_power_offset = self.geometry_to_triangle_power_offset.handle,
            .emissive_triangle_count = self.emissive_triangle_count.handle,
        });
        self.triangle_power_fold_pipeline.recordPushConstants(encoder.buffer, .{
            .instance_index = instance_index,
            .geometry_index = geometry_index,
            .triangle_count = primitive_count,
        });
        const dst_mip_size = std.math.pow(u32, 2, @intCast(self.triangle_powers_mips.len - dst_mip_level));
        const mip_dispatch_size = std.math.divCeil(u32, dst_mip_size, shader_local_size) catch unreachable;
        self.triangle_power_fold_pipeline.recordDispatch(encoder.buffer, .{ .width = mip_dispatch_size, .height = 1, .depth = 1 });
    }

    encoder.barrier(&[_]Encoder.ImageBarrier {
        Encoder.ImageBarrier {
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .general,
            .new_layout = .shader_read_only_optimal,
            .image = self.triangle_powers.handle,
            .base_mip_level = self.triangle_powers_mips.len - 1,
            .level_count = 1,
        }
    }, &.{});
}

// probably bad idea if you're changing many
// must recordRebuild to see changes
pub fn recordUpdateSingleInstanceProperties(self: *Self, encoder: *Encoder, instance_idx: u32, transform: Mat3x4, thin: bool, visible: bool) void {
    self.instances_host.hostSlice()[instance_idx].instance_custom_index_and_mask.mask = if (visible) if (thin) 0b10000000 else 0xFF else 0x00;
    self.instances_host.hostSlice()[instance_idx].transform = @bitCast(transform);
    self.world_to_instance_host.hostSlice()[instance_idx] = @bitCast(transform.inverseAffine());
    self.instances_device.uploadFrom(encoder, instance_idx, self.instances_host.deviceSlice().slice(instance_idx, instance_idx + 1));
    self.world_to_instance_device.uploadFrom(encoder, instance_idx, self.world_to_instance_host.deviceSlice().slice(instance_idx, instance_idx + 1));
    encoder.barrier(&.{}, &[_]Encoder.BufferBarrier {
        .{
            .src_stage_mask = .{ .copy_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true, .shader_storage_read_bit = true },
            .buffer = self.instances_device.handle,
            .offset = instance_idx * @sizeOf(vk.AccelerationStructureInstanceKHR),
            .size = @sizeOf(vk.AccelerationStructureInstanceKHR),
        },
        .{
            .src_stage_mask = .{ .copy_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true },
            .buffer = self.world_to_instance_device.handle,
            .offset = instance_idx * @sizeOf(vk.TransformMatrixKHR),
            .size = @sizeOf(vk.TransformMatrixKHR),
        },
    });
}

// probably bad idea if you're changing many
pub fn recordUpdateSingleMaterial(self: Self, command_buffer: VulkanContext.CommandBuffer, geometry_idx: u32, new_material_idx: u32) void {
    const offset = @sizeOf(Geometry) * geometry_idx + @offsetOf(Geometry, "material");
    const size = @sizeOf(u32);
    command_buffer.updateBuffer(self.geometries.handle, offset, size, &new_material_idx);
    command_buffer.pipelineBarrier2(&vk.DependencyInfo {
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

pub fn recordRebuild(self: *Self, command_buffer: VulkanContext.CommandBuffer) !void {
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

    command_buffer.buildAccelerationStructuresKHR(1, @ptrCast(&geometry_info), @ptrCast(&build_info_ref));

    const barriers = [_]vk.MemoryBarrier2 {
        .{
            .src_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .src_access_mask = .{ .acceleration_structure_write_bit_khr = true },
            .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true },
        }
    };
    command_buffer.pipelineBarrier2(&vk.DependencyInfo {
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

    self.triangle_powers.destroy(vc);
    self.triangle_powers_meta.destroy(vc);
    self.geometry_to_triangle_power_offset.destroy(vc);
    self.emissive_triangle_count.destroy(vc);

    self.triangle_power_pipeline.destroy(vc);
    self.triangle_power_fold_pipeline.destroy(vc);

    self.tlas_update_scratch_buffer.destroy(vc);

    for (self.triangle_powers_mips) |view| {
        vc.device.destroyImageView(view, null);
    }

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
