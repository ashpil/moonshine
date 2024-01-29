const std = @import("std");
const vk = @import("vulkan");
const shaders = @import("shaders");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const VkAllocator = core.Allocator;
const Commands = core.Commands;

const hrtsystem = engine.hrtsystem;
const Pipeline = hrtsystem.pipeline.ObjectPickPipeline;
const descriptor = core.descriptor;
const WorldDescriptorLayout = hrtsystem.World.DescriptorLayout;
const Sensor = core.Sensor;
const SensorDescriptorLayout = Sensor.DescriptorLayout;
const Camera = hrtsystem.Camera;

// must be kept in sync with shader
pub const DescriptorLayout = descriptor.DescriptorLayout(&.{
    .{
        .descriptor_type = .acceleration_structure_khr,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
    .{
        .descriptor_type = .storage_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
    .{
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
}, .{ .push_descriptor_bit_khr = true }, 1, "Input");

const F32x2 = @import("../vector.zig").Vec2(f32);

const Self = @This();

const ClickDataShader = extern struct {
    instance_index: i32, // -1 if clicked background
    geometry_index: u32,
    primitive_index: u32,
    barycentrics: F32x2,

    pub fn toClickedObject(self: ClickDataShader) ?ClickedObject {
        if (self.instance_index == -1) {
            return null;
        } else {
            return ClickedObject {
                .instance_index = @intCast(self.instance_index),
                .geometry_index = self.geometry_index,
                .primitive_index = self.primitive_index,
                .barycentrics = self.barycentrics,
            };
        }
    }
};

pub const ClickedObject = struct {
    instance_index: u32,
    geometry_index: u32,
    primitive_index: u32,
    barycentrics: F32x2,
};

buffer: VkAllocator.HostBuffer(ClickDataShader),
pipeline: Pipeline,

descriptor_layout: DescriptorLayout,

command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
ready_fence: vk.Fence,

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, world_layout: WorldDescriptorLayout, sensor_layout: SensorDescriptorLayout, commands: *Commands) !Self {
    const buffer = try vk_allocator.createHostBuffer(vc, ClickDataShader, 1, .{ .storage_buffer_bit = true });
    errdefer buffer.destroy(vc);

    var descriptor_layout = try DescriptorLayout.create(vc, .{});
    errdefer descriptor_layout.destroy(vc);

    var pipeline = try Pipeline.create(vc, vk_allocator, allocator, commands, .{ descriptor_layout, world_layout, sensor_layout }, .{});
    errdefer pipeline.destroy(vc);

    const command_pool = try vc.device.createCommandPool(&.{
        .queue_family_index = vc.physical_device.queue_family_index,
        .flags = .{ .transient_bit = true },
    }, null);
    errdefer vc.device.destroyCommandPool(command_pool, null);

    var command_buffer: vk.CommandBuffer = undefined;
    try vc.device.allocateCommandBuffers(&.{
        .level = vk.CommandBufferLevel.primary,
        .command_pool = command_pool,
        .command_buffer_count = 1,
    }, @ptrCast(&command_buffer));

    const ready_fence = try vc.device.createFence(&.{
        .flags = .{},
    }, null);
    errdefer vc.device.destroyFence(ready_fence, null);

    return Self {
        .buffer = buffer,
        .pipeline = pipeline,

        .descriptor_layout = descriptor_layout,

        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .ready_fence = ready_fence,
    };
}

pub fn getClickedObject(self: *Self, vc: *const VulkanContext, normalized_coords: F32x2, camera: Camera, accel: vk.AccelerationStructureKHR, sensor: Sensor) !?ClickedObject {
    // begin
    try vc.device.beginCommandBuffer(self.command_buffer, &.{ .flags = .{} });

    // bind pipeline + sets
    vc.device.cmdBindPipeline(self.command_buffer, .ray_tracing_khr, self.pipeline.handle);
    vc.device.cmdPushDescriptorSetKHR(self.command_buffer, .ray_tracing_khr, self.pipeline.layout, 0, 3, &[3]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .acceleration_structure_khr,
            .p_image_info = undefined,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
            .p_next = &vk.WriteDescriptorSetAccelerationStructureKHR {
                .acceleration_structure_count = 1,
                .p_acceleration_structures = @ptrCast(&accel),
            },
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                .sampler = .null_handle,
                .image_view = sensor.image.view,
                .image_layout = .general,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 2,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = self.buffer.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
    });

    const bytes = std.mem.asBytes(&.{ camera.lenses.items[0], normalized_coords });
    vc.device.cmdPushConstants(self.command_buffer, self.pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

    // trace rays
    const callable_table = vk.StridedDeviceAddressRegionKHR {
        .device_address = 0,
        .stride = 0,
        .size = 0,
    };
    vc.device.cmdTraceRaysKHR(self.command_buffer, &self.pipeline.sbt.getRaygenSBT(), &self.pipeline.sbt.getMissSBT(), &self.pipeline.sbt.getHitSBT(), &callable_table, 1, 1, 1);

    // end
    try vc.device.endCommandBuffer(self.command_buffer);

    const submit_info = vk.SubmitInfo2 {
        .flags = .{},
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = @ptrCast(&vk.CommandBufferSubmitInfo {
            .command_buffer = self.command_buffer,
            .device_mask = 0,
        }),
        .wait_semaphore_info_count = 0,
        .p_wait_semaphore_infos = undefined,
        .signal_semaphore_info_count = 0,
        .p_signal_semaphore_infos = undefined,
    };

    try vc.device.queueSubmit2(vc.queue, 1, @ptrCast(&submit_info), self.ready_fence);
    _ = try vc.device.waitForFences(1, @ptrCast(&self.ready_fence), vk.TRUE, std.math.maxInt(u64));
    try vc.device.resetFences(1, @ptrCast(&self.ready_fence));
    try vc.device.resetCommandPool(self.command_pool, .{});

    return self.buffer.data[0].toClickedObject();
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.descriptor_layout.destroy(vc);
    self.buffer.destroy(vc);
    self.pipeline.destroy(vc);
    vc.device.destroyCommandPool(self.command_pool, null);
    vc.device.destroyFence(self.ready_fence, null);
}
