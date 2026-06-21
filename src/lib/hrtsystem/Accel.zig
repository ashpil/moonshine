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
instances: core.mem.DeviceBuffer(vk.AccelerationStructureInstanceKHR, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true, .storage_buffer_bit = true }),
instances_address: vk.DeviceAddress,

// keep track of inverse transform -- non-inverse we can get from instances
// transforms provided by shader only in hit/intersection shaders but we need them
// in raygen
// ray queries provide them in any shader which would be a benefit of using them
world_to_instance: core.mem.DeviceBuffer(Mat4x3, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }),

// tlas stuff
tlas_handle: vk.AccelerationStructureKHR = .null_handle,
tlas_buffer: core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }) = .{},

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

    const instances = try core.mem.DeviceBuffer(vk.AccelerationStructureInstanceKHR, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true, .storage_buffer_bit = true }).create(vc, max_instances, "instances");
    errdefer instances.destroy(vc);
    const instances_address = instances.getAddress(vc);

    const world_to_instance = try core.mem.DeviceBuffer(Mat4x3, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, max_instances, "world to instances");
    errdefer world_to_instance.destroy(vc);

    return Self {
        .instance_power_pipeline = instance_power_pipeline,
        .instance_power_fold_pipeline = instance_power_fold_pipeline,
        .instance_powers = instance_powers,
        .instances = instances,
        .instances_address = instances_address,
        .world_to_instance = world_to_instance,
    };
}

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

        self.instances.updateFrom(encoder, self.instance_count, &.{ vk_instance });
    }

    // upload world_to_instance matrix
    {
        const transform = instance.transform.appendRow(.new(.{0, 0, 0, 1})).inverse().truncateRow();
        self.world_to_instance.updateFrom(encoder, self.instance_count, &.{ transform });
    }

    self.instance_count += 1;
    return @intCast(self.instance_count - 1);
}

// actually builds the composite acceleration structures from all instances. must be called for instance changes to take effect
pub fn build(self: *Self, vc: *const VulkanContext, encoder: *Encoder, model_manager: ModelManager) !void {
    encoder.barrier(&.{}, &[_]Encoder.BufferBarrier {
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .copy_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true, .compute_shader_bit = true },
            .dst_access_mask = .{ .memory_read_bit = true, .shader_read_bit = true },
            .buffer = self.instances.handle,
        },
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .copy_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true, .compute_shader_bit = true },
            .dst_access_mask = .{ .memory_read_bit = true, .shader_read_bit = true },
            .buffer = self.world_to_instance.handle,
        },
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .buffer = model_manager.models_device.handle,
        },
    });

    // update TLAS
    var geometry_info = vk.AccelerationStructureBuildGeometryInfoKHR {
        .type = .top_level_khr,
        .flags = .{ .prefer_fast_trace_bit_khr = true },
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

    try encoder.attachResource(self.tlas_buffer);
    self.tlas_buffer = try core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }).create(vc, size_info.acceleration_structure_size, "tlas buffer");

    try encoder.attachResource(self.tlas_handle);
    geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(&.{
        .buffer = self.tlas_buffer.handle,
        .offset = 0,
        .size = size_info.acceleration_structure_size,
        .type = .top_level_khr,
    }, null);
    self.tlas_handle = geometry_info.dst_acceleration_structure;

    geometry_info.scratch_data.device_address = scratch_buffer.getAddress(vc);

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
            .instances = self.instances.deviceSlice(),
            .world_to_instances = self.world_to_instance.deviceSlice(),
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

    encoder.buffer.pipelineBarrier2(&vk.DependencyInfo {
        .memory_barrier_count = 1,
        .p_memory_barriers = (&vk.MemoryBarrier2 {
            .src_stage_mask = .{ .acceleration_structure_build_bit_khr = true, .compute_shader_bit = true },
            .src_access_mask = .{ .acceleration_structure_write_bit_khr = true, .shader_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true, .shader_read_bit = true },
        })[0..1],
    });
}

// updates a single instance's data in place. must call build afterwards for the change to take effect.
pub fn recordUpdateSingleInstanceProperties(self: *Self, encoder: *Encoder, handle: Handle, instance: vk.AccelerationStructureInstanceKHR) void {
    self.instances.updateFrom(encoder, handle, &.{ instance });

    const transform: Mat4x3 = @bitCast(instance.transform);
    const inverse = transform.appendRow(.new(.{0, 0, 0, 1})).inverse().truncateRow();
    self.world_to_instance.updateFrom(encoder, handle, &.{ inverse });
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.instances.destroy(vc);
    self.world_to_instance.destroy(vc);

    self.instance_powers.destroy(vc);

    self.instance_power_pipeline.destroy(vc);
    self.instance_power_fold_pipeline.destroy(vc);

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
