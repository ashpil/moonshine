const std = @import("std");
const vk = @import("vulkan");
const shaders = @import("shaders");

const engine = @import("./engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;

const rendersystem = engine.rendersystem;
const VkAllocator = rendersystem.Allocator;
const Pipeline = rendersystem.pipeline.ObjectPickPipeline;
const descriptor = rendersystem.descriptor;
const InputDescriptorLayout = descriptor.InputDescriptorLayout;
const WorldDescriptorLayout = descriptor.WorldDescriptorLayout;
const Commands = rendersystem.Commands;
const Camera = rendersystem.Camera;
const F32x2 = @import("./vector.zig").Vec2(f32);
const toPointerType = engine.core.vk_helpers.toPointerType;

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
                .instance_index = @intCast(u32, self.instance_index),
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

descriptor_layout: InputDescriptorLayout,
descriptor_set: vk.DescriptorSet,

command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
ready_fence: vk.Fence,

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, world_layout: WorldDescriptorLayout, commands: *Commands) !Self {
    const buffer = try vk_allocator.createHostBuffer(vc, ClickDataShader, 1, .{ .storage_buffer_bit = true });

    const descriptor_layout = try InputDescriptorLayout.create(vc, 1, .{});

    const descriptor_set = try descriptor_layout.allocate_set(vc, [1]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = toPointerType(&vk.DescriptorBufferInfo {
                .buffer = buffer.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
    });

    const pipeline = try Pipeline.create(vc, vk_allocator, allocator, commands, .{ descriptor_layout, world_layout }, .{});

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
    }, @ptrCast([*]vk.CommandBuffer, &command_buffer));

    const ready_fence = try vc.device.createFence(&.{
        .flags = .{},
    }, null);

    return Self {
        .buffer = buffer,
        .pipeline = pipeline,

        .descriptor_layout = descriptor_layout,
        .descriptor_set = descriptor_set,

        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .ready_fence = ready_fence,
    };
}

pub fn getClickedObject(self: *Self, vc: *const VulkanContext, normalized_coords: F32x2, camera: Camera, tlas_descriptor_set: vk.DescriptorSet) !?ClickedObject {
    // begin
    try vc.device.beginCommandBuffer(self.command_buffer, &.{
        .flags = .{},
        .p_inheritance_info = null,
    });

    // bind pipeline + sets
    vc.device.cmdBindPipeline(self.command_buffer, .ray_tracing_khr, self.pipeline.handle);
    vc.device.cmdBindDescriptorSets(self.command_buffer, .ray_tracing_khr, self.pipeline.layout, 0, 2, &[_]vk.DescriptorSet { self.descriptor_set, tlas_descriptor_set }, 0, undefined);

    const bytes = std.mem.asBytes(&.{ camera.properties.origin, camera.properties.lower_left_corner, camera.properties.horizontal, camera.properties.vertical, normalized_coords });
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
        .p_command_buffer_infos = toPointerType(&vk.CommandBufferSubmitInfo {
            .command_buffer = self.command_buffer,
            .device_mask = 0,
        }),
        .wait_semaphore_info_count = 0,
        .p_wait_semaphore_infos = undefined,
        .signal_semaphore_info_count = 0,
        .p_signal_semaphore_infos = undefined,
    };

    try vc.device.queueSubmit2(vc.queue, 1, toPointerType(&submit_info), self.ready_fence);
    _ = try vc.device.waitForFences(1, toPointerType(&self.ready_fence), vk.TRUE, std.math.maxInt(u64));
    try vc.device.resetFences(1, toPointerType(&self.ready_fence));
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
