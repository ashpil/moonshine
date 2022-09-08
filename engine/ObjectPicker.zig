const std = @import("std");
const vk = @import("vulkan");
const shaders = @import("shaders");

const VulkanContext = @import("./rendersystem/VulkanContext.zig");
const VkAllocator = @import("./rendersystem/Allocator.zig");
const Pipeline = @import("./rendersystem/Pipeline.zig");
const InputDescriptorLayout = @import("./rendersystem/descriptor.zig").InputDescriptorLayout;
const Commands = @import("./rendersystem/Commands.zig");
const Camera = @import("./rendersystem/Camera.zig");
const F32x2 = @import("./vector.zig").Vec2(f32);
const utils = @import("./rendersystem/utils.zig");

const Self = @This();

pub const ClickData = struct {
    instance_index: i32,
    primitive_index: u32,
    barycentrics: F32x2,
};

buffer: VkAllocator.HostBuffer(ClickData),
pipeline: Pipeline,

descriptor_layout: InputDescriptorLayout,
descriptor_set: vk.DescriptorSet,

command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,
ready_fence: vk.Fence,

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, accel_layout: vk.DescriptorSetLayout, commands: *Commands) !Self {
    const buffer = try vk_allocator.createHostBuffer(vc, ClickData, 1, .{ .storage_buffer_bit = true });

    const descriptor_layout = try InputDescriptorLayout.create(vc, 1, null);

    const descriptor_set = (try descriptor_layout.allocate_sets(vc, 1, [1]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
                .buffer = buffer.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
    }))[0];

    const shader_module = try vc.device.createShaderModule(&.{
        .flags = .{},
        .code_size = shaders.input.len,
        .p_code = @ptrCast([*]const u32, shaders.input),
    }, null);
    defer vc.device.destroyShaderModule(shader_module, null);

    const pipeline = try Pipeline.create(vc, vk_allocator, allocator, commands, &.{ descriptor_layout.handle, accel_layout }, &[_]vk.PipelineShaderStageCreateInfo {
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .raygen_bit_khr = true }, .module = shader_module, .p_name = "raygen", .p_specialization_info = null, },
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .miss_bit_khr = true }, .module = shader_module, .p_name = "miss", .p_specialization_info = null, },
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .closest_hit_bit_khr = true }, .module = shader_module, .p_name = "chit", .p_specialization_info = null, },
    }, &[_]vk.RayTracingShaderGroupCreateInfoKHR {
        .{ .@"type" = .general_khr, .general_shader = 0, .closest_hit_shader = vk.SHADER_UNUSED_KHR, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
        .{ .@"type" = .general_khr, .general_shader = 1, .closest_hit_shader = vk.SHADER_UNUSED_KHR, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
        .{ .@"type" = .triangles_hit_group_khr, .general_shader = vk.SHADER_UNUSED_KHR, .closest_hit_shader = 2, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
    }, &[_]vk.PushConstantRange {
        .{
            .offset = 0,
            .size = @sizeOf(Camera.Desc) + @sizeOf(F32x2),
            .stage_flags = .{ .raygen_bit_khr = true },
        }
    });

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

pub fn getClick(self: *Self, vc: *const VulkanContext, normalized_coords: F32x2, camera: Camera, tlas_descriptor_set: vk.DescriptorSet) !ClickData {
    // begin
    try vc.device.beginCommandBuffer(self.command_buffer, &.{
        .flags = .{},
        .p_inheritance_info = null,
    });

    // bind pipeline + sets
    vc.device.cmdBindPipeline(self.command_buffer, .ray_tracing_khr, self.pipeline.handle);
    vc.device.cmdBindDescriptorSets(self.command_buffer, .ray_tracing_khr, self.pipeline.layout, 0, 2, &[_]vk.DescriptorSet { self.descriptor_set, tlas_descriptor_set }, 0, undefined);

    // push constants
    const bytes = std.mem.asBytes(&.{ camera.desc, normalized_coords });
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
        .p_command_buffer_infos = utils.toPointerType(&vk.CommandBufferSubmitInfo {
            .command_buffer = self.command_buffer,
            .device_mask = 0,
        }),
        .wait_semaphore_info_count = 0,
        .p_wait_semaphore_infos = undefined,
        .signal_semaphore_info_count = 0,
        .p_signal_semaphore_infos = undefined,
    };

    try vc.device.queueSubmit2(vc.queue, 1, utils.toPointerType(&submit_info), self.ready_fence);
    _ = try vc.device.waitForFences(1, utils.toPointerType(&self.ready_fence), vk.TRUE, std.math.maxInt(u64));
    try vc.device.resetFences(1, utils.toPointerType(&self.ready_fence));
    try vc.device.resetCommandPool(self.command_pool, .{});

    return self.buffer.data[0];
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.descriptor_layout.destroy(vc);
    self.buffer.destroy(vc);
    self.pipeline.destroy(vc);
    vc.device.destroyCommandPool(self.command_pool, null);
    vc.device.destroyFence(self.ready_fence, null);
}
