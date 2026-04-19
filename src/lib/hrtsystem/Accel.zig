const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const Image = core.Image;

const MeshManager = @import("./MeshManager.zig");
const MaterialManager = @import("./MaterialManager.zig");
const ModelManager = @import("./ModelManager.zig");

const vector = @import("../vector.zig");
const Mat4x3 = vector.Mat4x3(f32);
const F32x3 = vector.Vec3(f32);
const F32x4 = vector.Vec4(f32);

const shaders = @import("hrtsystem_shaders");

// "accel" perhaps the wrong name for this struct at this point, maybe "heirarchy" would be better
// the acceleration structure is the primary world heirarchy, and controls
// how all the meshes and materials fit together

pub const Instance = struct {
    transform: Mat4x3,
    visible: bool = true,
    thin: bool = true,
    priority: u4 = 1, // 1-7 valid values
    model: ModelManager.Handle,
};

const InstancePowerPipeline = engine.core.pipeline.Pipeline(.{ .shader_source = shaders.instance_power,
    .local_size = vk.Extent3D { .width = 32, .height = 1, .depth = 1 },
    .PushConstants = extern struct {
        instance_count: u32,
        dst_offset: u32,
    },
    .PushSetBindings = struct {
        instances: core.mem.BufferSlice(vk.AccelerationStructureInstanceKHR),
        world_to_instances: core.mem.BufferSlice(Mat4x3),
        models: core.mem.BufferSlice(ModelManager.Model.Device),
        dst_power: core.mem.BufferSlice(F32x3),
    },
});

const InstancePowerFoldPipeline = engine.core.pipeline.Pipeline(.{ .shader_source = shaders.fold1,
    .local_size = vk.Extent3D { .width = 32, .height = 1, .depth = 1 },
    .PushConstants = extern struct {
        src_level_offset: u32,
        dst_level_offset: u32,
        max_src_index: u32,
    },
    .PushSetBindings = struct {
        levels: core.mem.BufferSlice(F32x3),
    },
});

instance_power_pipeline: InstancePowerPipeline,
instance_power_fold_pipeline: InstancePowerFoldPipeline,
instance_powers: core.mem.DeviceBuffer(F32x3, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }),

instance_count: u32 = 0,
instances_device: core.mem.DeviceBuffer(vk.AccelerationStructureInstanceKHR, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true, .storage_buffer_bit = true }),
instances_host: core.mem.UploadBuffer(vk.AccelerationStructureInstanceKHR),
instances_address: vk.DeviceAddress,

// keep track of inverse transform -- non-inverse we can get from instances_device
// transforms provided by shader only in hit/intersection shaders but we need them
// in raygen
// ray queries provide them in any shader which would be a benefit of using them
world_to_instance_device: core.mem.DeviceBuffer(Mat4x3, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }),
world_to_instance_host: core.mem.UploadBuffer(Mat4x3),

// tlas stuff
tlas_handle: vk.AccelerationStructureKHR = .null_handle,
tlas_buffer: core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }) = .{},

tlas_update_scratch_buffer: core.mem.DeviceBuffer(u8, .{ .storage_buffer_bit = true, .shader_device_address_bit = true }) = .{},
tlas_update_scratch_address: vk.DeviceAddress = 0,

const Self = @This();

// TODO: resizable buffers
const max_instances = std.math.pow(u32, 2, 12);

pub fn createEmpty(vc: *const VulkanContext) !Self {
    var instance_power_pipeline = try InstancePowerPipeline.create(vc, .{}, .{}, .{});
    errdefer instance_power_pipeline.destroy(vc);

    var instance_power_fold_pipeline = try InstancePowerFoldPipeline.create(vc, .{}, .{}, .{});
    errdefer instance_power_fold_pipeline.destroy(vc);

    std.debug.assert(max_instances % 2 == 0);
    const instance_powers_level_count = comptime std.math.log2(max_instances) + 1;
    const instance_powers_element_count = std.math.pow(u32, 2, instance_powers_level_count) - 1;
    const instance_powers = try core.mem.DeviceBuffer(F32x3, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, instance_powers_element_count, "instance powers");
    errdefer instance_powers.destroy(vc);

    const instances_device = try core.mem.DeviceBuffer(vk.AccelerationStructureInstanceKHR, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true, .storage_buffer_bit = true }).create(vc, max_instances, "instances");
    errdefer instances_device.destroy(vc);
    const instances_host = try core.mem.UploadBuffer(vk.AccelerationStructureInstanceKHR).create(vc, max_instances, "instances");
    errdefer instances_host.destroy(vc);
    const instances_address = instances_device.getAddress(vc);

    const world_to_instance_device = try core.mem.DeviceBuffer(Mat4x3, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, max_instances, "world to instances");
    errdefer world_to_instance_device.destroy(vc);
    const world_to_instance_host = try core.mem.UploadBuffer(Mat4x3).create(vc, max_instances, "world to instances");
    errdefer world_to_instance_host.destroy(vc);

    return Self {
        .instance_power_pipeline = instance_power_pipeline,
        .instance_power_fold_pipeline = instance_power_fold_pipeline,
        .instance_powers = instance_powers,
        .instances_device = instances_device,
        .instances_host = instances_host,
        .instances_address = instances_address,
        .world_to_instance_device = world_to_instance_device,
        .world_to_instance_host = world_to_instance_host,
    };
}

// accel must not be in use
pub const Handle = u32;
pub fn uploadInstance(self: *Self, vc: *const VulkanContext, encoder: *Encoder, model_manager: ModelManager, instance: Instance) !Handle {
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
                .acceleration_structure = model_manager.models_host.items(.blas_handle)[instance.model],
            }),
        };

        self.instances_host.hostSlice()[self.instance_count] = vk_instance;
        self.instances_device.uploadFrom(encoder, self.instance_count, self.instances_host.deviceSlice().slice(self.instance_count, self.instance_count + 1));
    }

    // upload world_to_instance matrix
    {
        self.world_to_instance_host.hostSlice()[self.instance_count] = instance.transform.appendRow(.new(.{0, 0, 0, 1})).inverse().truncateRow();
        self.world_to_instance_device.uploadFrom(encoder, self.instance_count, self.world_to_instance_host.deviceSlice().slice(self.instance_count, self.instance_count + 1));
    }

    encoder.barrier(&.{}, &[_]Encoder.BufferBarrier {
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .copy_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .dst_access_mask = .{ .memory_read_bit = true },
            .buffer = self.instances_device.handle,
        },
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .copy_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true, .compute_shader_bit = true },
            .dst_access_mask = .{ .memory_read_bit = true, .shader_read_bit = true },
            .buffer = self.world_to_instance_device.handle,
        },
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .buffer = model_manager.models_device.handle,
        },
    });

    self.instance_count += 1;

    // update TLAS
    var geometry_info = vk.AccelerationStructureBuildGeometryInfoKHR {
        .type = .top_level_khr,
        .flags = .{ .prefer_fast_trace_bit_khr = true, .allow_update_bit_khr = true },
        .mode = .build_khr,
        .geometry_count = 1,
        .p_geometries = (&vk.AccelerationStructureGeometryKHR {
            .geometry_type = .instances_khr,
            .flags = .{ .opaque_bit_khr = true },
            .geometry = .{
                .instances = .{
                    .array_of_pointers = .false,
                    .data = .{
                        .device_address = self.instances_address,
                    }
                }
            },
        })[0..1],
        .scratch_data = undefined,
    };

    const size_info = getBuildSizesInfo(vc, &geometry_info, (&self.instance_count)[0..1]);

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

    encoder.buildAccelerationStructures(&.{ geometry_info }, &[_][*]const vk.AccelerationStructureBuildRangeInfoKHR{ (&vk.AccelerationStructureBuildRangeInfoKHR {
        .primitive_count = @intCast(self.instance_count),
        .first_vertex = 0,
        .primitive_offset = 0,
        .transform_offset = 0,
    })[0..1]});

    {
        const instance_powers_level_count = comptime std.math.log2(max_instances) + 1;
        const instance_powers_element_count = std.math.pow(u32, 2, instance_powers_level_count) - 1;

        self.instance_power_pipeline.recordBindPipeline(encoder.buffer);
        self.instance_power_pipeline.recordPushDescriptors(encoder.buffer, .{
            .instances = self.instances_device.deviceSlice(),
            .world_to_instances = self.world_to_instance_device.deviceSlice(),
            .models = model_manager.models_device.deviceSlice(),
            .dst_power = self.instance_powers.deviceSlice(),
        });
        self.instance_power_pipeline.recordPushConstants(encoder.buffer, .{
            .instance_count = self.instance_count,
            .dst_offset = instance_powers_element_count - max_instances,
        });
        self.instance_power_pipeline.recordDispatchThreads1D(encoder.buffer, self.instance_count);
        self.instance_power_fold_pipeline.recordBindPipeline(encoder.buffer);

        for (1..instance_powers_level_count) |src_level_rev| {
            const src_level: u32 = @intCast(instance_powers_level_count - src_level_rev);
            encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
                Encoder.BufferBarrier {
                    .src_stage_mask = .{ .compute_shader_bit = true },
                    .src_access_mask = .{ .shader_write_bit = true },
                    .dst_stage_mask = .{ .compute_shader_bit = true },
                    .dst_access_mask = .{ .shader_read_bit = true },
                    .buffer = self.instance_powers.handle,
                },
            });
            const dst_level_size = std.math.pow(u32, 2, src_level);
            self.instance_power_fold_pipeline.recordPushDescriptors(encoder.buffer, .{
                .levels = self.instance_powers.deviceSlice(),
            });
            self.instance_power_fold_pipeline.recordPushConstants(encoder.buffer, .{
                .src_level_offset = std.math.pow(u32, 2, src_level - 0) - 1,
                .dst_level_offset = std.math.pow(u32, 2, src_level - 1) - 1,
                .max_src_index = self.instance_count,
            });
            self.instance_power_fold_pipeline.recordDispatchThreads1D(encoder.buffer, dst_level_size);
        }
    }

    return @intCast(self.instance_count - 1);
}

// probably bad idea if you're changing many
// must recordRebuild to see changes
pub fn recordUpdateSingleInstanceProperties(self: *Self, encoder: *Encoder, instance_idx: u32, transform: Mat4x3, thin: bool, priority: u4, visible: bool) void {
    self.instances_host.hostSlice()[instance_idx].instance_custom_index_and_mask.mask = if (visible) if (thin) 0b10000000 else @as(u8, 1) << @intCast(priority - 1) else 0x00;
    self.instances_host.hostSlice()[instance_idx].transform = @bitCast(transform);
    self.world_to_instance_host.hostSlice()[instance_idx] = @bitCast(transform.appendRow(.new(.{0, 0, 0, 1})).inverse().truncateRow());
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
            .dst_stage_mask = .{ .compute_shader_bit = true },
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
                .array_of_pointers = .false,
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
        .p_geometries = (&geometry)[0..1],
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

    const build_info_ref = @as([*]const vk.AccelerationStructureBuildRangeInfoKHR, (&build_info)[0..1]);

    command_buffer.buildAccelerationStructuresKHR((&geometry_info)[0..1], (&build_info_ref)[0..1]);

    const barriers = [_]vk.MemoryBarrier2 {
        .{
            .src_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .src_access_mask = .{ .acceleration_structure_write_bit_khr = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
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

    self.instance_powers.destroy(vc);

    self.instance_power_pipeline.destroy(vc);
    self.instance_power_fold_pipeline.destroy(vc);

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
