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
const ModelManager = @import("./ModelManager.zig");

const vector = @import("../vector.zig");
const Mat3x4 = vector.Mat3x4(f32);

// "accel" perhaps the wrong name for this struct at this point, maybe "heirarchy" would be better
// the acceleration structure is the primary world heirarchy, and controls
// how all the meshes and materials fit together

pub const Instance = struct {
    transform: Mat3x4,
    visible: bool = true,
    thin: bool = true,
    priority: u4 = 1, // 1-7 valid values
    model: ModelManager.Handle,
};

const TrianglePowerPipeline = engine.core.pipeline.Pipeline(.{ .shader_path = "hrtsystem/mesh_sampling/power.hlsl",
    .PushConstants = extern struct {
        instance_index: u32,
        geometry_index: u32,
        triangle_count: u32,
    },
    .PushSetBindings = struct {
        instances: core.mem.BufferSlice(vk.AccelerationStructureInstanceKHR),
        world_to_instances: core.mem.BufferSlice(Mat3x4),
        meshes: core.mem.BufferSlice(engine.hrtsystem.MeshManager.Mesh.Device),
        geometries: core.mem.BufferSlice(engine.hrtsystem.ModelManager.Geometry),
        model_to_geometry_offset: core.mem.BufferSlice(u32),
        materials: core.mem.BufferSlice(engine.hrtsystem.MaterialManager.Material.Device),
        emissive_triangle_count: core.mem.BufferSlice(u32),
        dst_power: core.mem.BufferSlice(f32),
        dst_triangle_metadata: core.mem.BufferSlice(TriangleMetadata),
    },
    .additional_descriptor_layout_count = 1,
});

const TrianglePowerFoldPipeline = engine.core.pipeline.Pipeline(.{ .shader_path = "hrtsystem/mesh_sampling/fold.hlsl",
    .PushSetBindings = struct {
        levels: core.mem.BufferSlice(f32),
        instances: core.mem.BufferSlice(vk.AccelerationStructureInstanceKHR),
        geometry_to_triangle_power_offset: core.mem.BufferSlice(u32),
        emissive_triangle_count: core.mem.BufferSlice(u32),
    },
    .PushConstants = extern struct {
        instance_index: u32,
        geometry_index: u32,
        triangle_count: u32,
        src_level_offset: u32,
        dst_level_offset: u32,
    },
});

pub const TriangleMetadata = extern struct {
    instance_index: u32,
    geometry_index: u32,
};

triangle_power_pipeline: TrianglePowerPipeline,
triangle_power_fold_pipeline: TrianglePowerFoldPipeline,
triangle_powers_meta: core.mem.DeviceBuffer(TriangleMetadata, .{ .storage_buffer_bit = true }),
// TODO: should build a separate one for each model so that instances are actually instanced here
triangle_powers: core.mem.DeviceBuffer(f32, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }),
geometry_to_triangle_power_offset: core.mem.DeviceBuffer(u32, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }) = .{},
emissive_triangle_count: core.mem.DeviceBuffer(u32, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }), // size 1

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

// tlas stuff
tlas_handle: vk.AccelerationStructureKHR = .null_handle,
tlas_buffer: core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }) = .{},

tlas_update_scratch_buffer: core.mem.DeviceBuffer(u8, .{ .storage_buffer_bit = true, .shader_device_address_bit = true }) = .{},
tlas_update_scratch_address: vk.DeviceAddress = 0,

const Self = @This();

// TODO: resizable buffers
const max_instances = std.math.pow(u32, 2, 12);
const max_geometries = std.math.pow(u32, 2, 12);
const max_emissive_triangles = std.math.pow(u32, 2, 15);

pub fn createEmpty(vc: *const VulkanContext, allocator: std.mem.Allocator, texture_descriptor_layout: MaterialManager.TextureManager.DescriptorLayout, encoder: *Encoder) !Self {
    var triangle_power_pipeline = try TrianglePowerPipeline.create(vc, allocator, .{}, .{}, .{ texture_descriptor_layout.handle });
    errdefer triangle_power_pipeline.destroy(vc);

    var triangle_power_fold_pipeline = try TrianglePowerFoldPipeline.create(vc, allocator, .{}, .{}, .{});
    errdefer triangle_power_fold_pipeline.destroy(vc);

    const triangle_powers_meta = try core.mem.DeviceBuffer(TriangleMetadata, .{ .storage_buffer_bit = true }).create(vc, max_emissive_triangles, "triangle powers meta");
    errdefer triangle_powers_meta.destroy(vc);

    const emissive_triangle_count = try core.mem.DeviceBuffer(u32, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, 1, "emissive triangle count");
    errdefer emissive_triangle_count.destroy(vc);

    std.debug.assert(max_emissive_triangles % 2 == 0);
    const emissive_triangle_level_count = comptime std.math.log2(max_emissive_triangles) + 1;
    const triangle_powers_element_count = std.math.pow(u32, 2, emissive_triangle_level_count) - 1;
    const triangle_powers = try core.mem.DeviceBuffer(f32, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, triangle_powers_element_count, "triangle powers");
    errdefer triangle_powers.destroy(vc);

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

    encoder.fillBuffer(emissive_triangle_count.handle, 1, @as(u32, 0));
    encoder.fillBuffer(geometry_to_triangle_power_offset.handle, max_geometries, @as(u32, std.math.maxInt(u32)));
    encoder.fillBuffer(triangle_powers.handle, triangle_powers_element_count, @as(f32, 0.0));

    encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true, .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
            .buffer = emissive_triangle_count.handle,
        },
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true, .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
            .buffer = geometry_to_triangle_power_offset.handle,
        },
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true, .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
            .buffer = triangle_powers.handle,
        },
    });

    return Self {
        .triangle_power_pipeline = triangle_power_pipeline,
        .triangle_power_fold_pipeline = triangle_power_fold_pipeline,
        .triangle_powers_meta = triangle_powers_meta,
        .triangle_powers = triangle_powers,
        .emissive_triangle_count = emissive_triangle_count,
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
// TODO: instance light accel so that geometry does not need to be passed into here
pub fn uploadInstance(self: *Self, vc: *const VulkanContext, encoder: *Encoder, mesh_manager: MeshManager, material_manager: MaterialManager, model_manager: ModelManager, instance: Instance, geometries: []const ModelManager.Geometry) !Handle {
    std.debug.assert(self.instance_count < max_instances);

    // upload instance
    {
        const vk_instance = vk.AccelerationStructureInstanceKHR {
            .transform = vk.TransformMatrixKHR {
                .matrix = @bitCast(instance.transform),
            },
            .instance_custom_index_and_mask = .{
                .instance_custom_index = instance.model,
                .mask = if (instance.visible) if (instance.thin) 0b10000000 else @as(u8, 1) << @intCast(instance.priority - 1) else 0x00,
            },
            .instance_shader_binding_table_record_offset_and_flags = .{
                .instance_shader_binding_table_record_offset = 0,
                .flags = 0,
            },
            .acceleration_structure_reference = vc.device.getAccelerationStructureDeviceAddressKHR(&.{
                .acceleration_structure = model_manager.blases.items(.handle)[instance.model],
            }),
        };

        self.instances_host.hostSlice()[self.instance_count] = vk_instance;
        self.instances_device.uploadFrom(encoder, self.instance_count, self.instances_host.deviceSlice().slice(self.instance_count, self.instance_count + 1));
    }

    // upload world_to_instance matrix
    {
        self.world_to_instance_host.hostSlice()[self.instance_count] = instance.transform.inverseAffine();
        self.world_to_instance_device.uploadFrom(encoder, self.instance_count, self.world_to_instance_host.deviceSlice().slice(self.instance_count, self.instance_count + 1));
    }

    encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .copy_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .dst_access_mask = .{ .memory_read_bit = true },
            .buffer = self.instances_device.handle,
        },
    });

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

    encoder.global_barrier();
    for (geometries, 0..) |geometry, i| {
        self.recordUpdatePower(encoder, mesh_manager, material_manager, model_manager, @intCast(self.instance_count - 1), @intCast(i), geometry.mesh);
    }
    encoder.global_barrier();

    return @intCast(self.instance_count - 1);
}

pub fn recordUpdatePower(self: *Self, encoder: *Encoder, mesh_manager: MeshManager, material_manager: MaterialManager, model_manager: ModelManager, instance_index: u32, geometry_index: u32, mesh_index: u32) void {
    const mesh = mesh_manager.host.get(mesh_index);
    const primitive_count = if (mesh.index_count != 0) mesh.index_count else @divExact(mesh.vertex_count, 3);

    // this mesh is too big to importance sample...
    // it may still emit without importance sampling, though
    //
    // TODO: technically this should check that the that total (in the whole scene) emissive triangle count is less than
    // the maximum number of emissive triangles, but we don't have access to that info on the host.
    // probably we will just get a GPU crash instead :(
    if (primitive_count > max_emissive_triangles) return;

    const emissive_triangle_level_count = comptime std.math.log2(max_emissive_triangles) + 1;

    self.triangle_power_pipeline.recordBindPipeline(encoder.buffer);
    self.triangle_power_pipeline.recordBindAdditionalDescriptorSets(encoder.buffer, .{ material_manager.textures.descriptor_set });
    self.triangle_power_pipeline.recordPushDescriptors(encoder.buffer, .{
        .instances = self.instances_device.deviceSlice(),
        .world_to_instances = self.world_to_instance_device.deviceSlice(),
        .meshes = mesh_manager.device.deviceSlice(),
        .geometries = model_manager.geometries.deviceSlice(),
        .model_to_geometry_offset = model_manager.model_to_geometry_offset.deviceSlice(),
        .materials = material_manager.materials.deviceSlice(),
        .emissive_triangle_count = self.emissive_triangle_count.deviceSlice(),
        .dst_power = self.triangle_powers.deviceSlice(),
        .dst_triangle_metadata = self.triangle_powers_meta.deviceSlice(),
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

    for (1..emissive_triangle_level_count) |dst_level_usize| {
        const dst_level: u32 = @intCast(dst_level_usize);
        encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
            Encoder.BufferBarrier {
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .buffer = self.triangle_powers.handle,
            },
        });
        const dst_level_size = std.math.pow(u32, 2, @intCast(emissive_triangle_level_count - dst_level));
        self.triangle_power_fold_pipeline.recordPushDescriptors(encoder.buffer, .{
            .levels = self.triangle_powers.deviceSlice(),
            .instances = self.instances_device.deviceSlice(),
            .geometry_to_triangle_power_offset = self.geometry_to_triangle_power_offset.deviceSlice(),
            .emissive_triangle_count = self.emissive_triangle_count.deviceSlice(),
        });
        self.triangle_power_fold_pipeline.recordPushConstants(encoder.buffer, .{
            .instance_index = instance_index,
            .geometry_index = geometry_index,
            .triangle_count = primitive_count,
            .src_level_offset = std.math.pow(u32, 2, emissive_triangle_level_count - dst_level - 0) - 1,
            .dst_level_offset = std.math.pow(u32, 2, emissive_triangle_level_count - dst_level - 1) - 1,
        });
        const mip_dispatch_size = std.math.divCeil(u32, dst_level_size, shader_local_size) catch unreachable;
        self.triangle_power_fold_pipeline.recordDispatch(encoder.buffer, .{ .width = mip_dispatch_size, .height = 1, .depth = 1 });
    }

    encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .buffer = self.triangle_powers.handle,
        },
    });
}

// probably bad idea if you're changing many
// must recordRebuild to see changes
pub fn recordUpdateSingleInstanceProperties(self: *Self, encoder: *Encoder, instance_idx: u32, transform: Mat3x4, thin: bool, priority: u4, visible: bool) void {
    self.instances_host.hostSlice()[instance_idx].instance_custom_index_and_mask.mask = if (visible) if (thin) 0b10000000 else @as(u8, 1) << @intCast(priority - 1) else 0x00;
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

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.instances_device.destroy(vc);
    self.instances_host.destroy(vc);
    self.world_to_instance_device.destroy(vc);
    self.world_to_instance_host.destroy(vc);

    self.triangle_powers.destroy(vc);
    self.triangle_powers_meta.destroy(vc);
    self.geometry_to_triangle_power_offset.destroy(vc);
    self.emissive_triangle_count.destroy(vc);

    self.triangle_power_pipeline.destroy(vc);
    self.triangle_power_fold_pipeline.destroy(vc);

    self.tlas_update_scratch_buffer.destroy(vc);

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
