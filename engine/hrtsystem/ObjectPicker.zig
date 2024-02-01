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
const Sensor = core.Sensor;
const Camera = hrtsystem.Camera;

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

command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
ready_fence: vk.Fence,

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands) !Self {
    const buffer = try vk_allocator.createHostBuffer(vc, ClickDataShader, 1, .{ .storage_buffer_bit = true });
    errdefer buffer.destroy(vc);

    var pipeline = try Pipeline.create(vc, vk_allocator, allocator, commands, {}, .{}, .{});
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

        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .ready_fence = ready_fence,
    };
}

pub fn getClickedObject(self: *Self, vc: *const VulkanContext, normalized_coords: F32x2, camera: Camera, accel: vk.AccelerationStructureKHR, sensor: Sensor) !?ClickedObject {
    // begin
    try vc.device.beginCommandBuffer(self.command_buffer, &.{ .flags = .{} });

    // bind pipeline + sets
    self.pipeline.recordBindPipeline(vc, self.command_buffer);
    self.pipeline.recordPushDescriptors(vc, self.command_buffer, Pipeline.PushDescriptorData {
        .tlas = accel,
        .output_image = sensor.image.view,
        .click_data = self.buffer.handle,
    });

    self.pipeline.recordPushConstants(vc, self.command_buffer, .{ .lens = camera.lenses.items[0], .click_position = normalized_coords });

    // trace rays
    self.pipeline.recordTraceRays(vc, self.command_buffer, vk.Extent2D { .width = 1, .height = 1 });

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
    self.buffer.destroy(vc);
    self.pipeline.destroy(vc);
    vc.device.destroyCommandPool(self.command_pool, null);
    vc.device.destroyFence(self.ready_fence, null);
}
