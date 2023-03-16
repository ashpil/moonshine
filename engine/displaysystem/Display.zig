const std = @import("std");
const vk = @import("vulkan");

const rendersystem = @import("../engine.zig").rendersystem;
const VulkanContext = rendersystem.VulkanContext;
const VkAllocator = rendersystem.Allocator;
const Pipeline = rendersystem.pipeline.StandardPipeline;
const Commands = rendersystem.Commands;
const utils = rendersystem.utils;

const Swapchain = @import("./Swapchain.zig");
const DestructionQueue = @import("./DestructionQueue.zig");

const metrics = @import("build_options").vk_metrics;

pub const frames_in_flight = 2;

const Self = @This();

frames: [frames_in_flight]Frame,
frame_index: u8,

swapchain: Swapchain,

destruction_queue: DestructionQueue,

timestamp_period: if (metrics) f32 else void,
last_frame_time_ns: if (metrics) f64 else void,

// uses initial_extent as the render extent -- that is, the buffer that is actually being rendered into, irrespective of window size
// then during rendering the render buffer is blitted into the swapchain images
pub fn create(vc: *const VulkanContext, initial_extent: vk.Extent2D, surface: vk.SurfaceKHR) !Self {
    var swapchain = try Swapchain.create(vc, initial_extent, surface);
    errdefer swapchain.destroy(vc);

    var frames: [frames_in_flight]Frame = undefined;
    inline for (&frames, 0..) |*frame, i| {
        frame.* = try Frame.create(vc);
        try utils.setDebugName(vc, frame.command_buffer, std.fmt.comptimePrint("frame {}", .{i}));
    }
    try vc.device.resetFences(1, @ptrCast([*]const vk.Fence, &frames[0].fence));

    const timestamp_period = if (metrics) blk: {
        var properties = vk.PhysicalDeviceProperties2 {
            .properties = undefined,
            .p_next = null,
        };

        vc.instance.getPhysicalDeviceProperties2(vc.physical_device.handle, &properties);

        break :blk properties.properties.limits.timestamp_period;
    } else {};

    return Self {
        .swapchain = swapchain,
        .frames = frames,
        .frame_index = 0,

        .destruction_queue = DestructionQueue.create(), // TODO: need to clean this every once in a while since we're only allowed a limited amount of most types of handles

        .timestamp_period = timestamp_period,
        .last_frame_time_ns = if (metrics) 0.0 else {},
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.swapchain.destroy(vc);
    inline for (&self.frames) |*frame| {
        frame.destroy(vc);
    }
    self.destruction_queue.destroy(vc, allocator);
}

pub fn startFrame(self: *Self, vc: *const VulkanContext) !vk.CommandBuffer {
    const frame = self.frames[self.frame_index];

    _ = try self.swapchain.acquireNextImage(vc, frame.image_acquired);
    if (metrics) {
        var timestamps: [2]u64 = undefined;
        const result = try vc.device.getQueryPoolResults(frame.query_pool, 0, 2, 2 * @sizeOf(u64), &timestamps, @sizeOf(u64), .{.@"64_bit" = true });
        self.last_frame_time_ns = if (result == .success) @intToFloat(f64, timestamps[1] - timestamps[0]) * self.timestamp_period else std.math.nan(f64);
        vc.device.resetQueryPool(frame.query_pool, 0, 2);
    }

    try vc.device.resetCommandPool(frame.command_pool, .{});
    try vc.device.beginCommandBuffer(frame.command_buffer, &.{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    if (metrics) vc.device.cmdWriteTimestamp2(frame.command_buffer, .{ .top_of_pipe_bit = true }, frame.query_pool, 0);

    return frame.command_buffer;
}

pub fn recreate(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, new_extent: vk.Extent2D) !void {
    try self.destruction_queue.add(allocator, self.swapchain.handle);
    try self.swapchain.recreate(vc, new_extent);
}

pub fn endFrame(self: *Self, vc: *const VulkanContext) !vk.Result {
    const frame = self.frames[self.frame_index];

    if (metrics) vc.device.cmdWriteTimestamp2(frame.command_buffer, .{ .bottom_of_pipe_bit = true }, frame.query_pool, 1);

    try vc.device.endCommandBuffer(frame.command_buffer);

    // TODO: these sync stage flags are probably wrong
    try vc.device.queueSubmit2(vc.queue, 1, &[_]vk.SubmitInfo2 { .{
        .flags = .{},
        .wait_semaphore_info_count = 1,
        .p_wait_semaphore_infos = utils.toPointerType(&vk.SemaphoreSubmitInfoKHR{
            .semaphore = frame.image_acquired,
            .value = 0,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .device_index = 0,
        }),
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = utils.toPointerType(&vk.CommandBufferSubmitInfo {
            .command_buffer = frame.command_buffer,
            .device_mask = 0,
        }),
        .signal_semaphore_info_count = 1,
        .p_signal_semaphore_infos = utils.toPointerType(&vk.SemaphoreSubmitInfoKHR {
            .semaphore = frame.command_completed,
            .value = 0,
            .stage_mask =  .{ .color_attachment_output_bit = true },
            .device_index = 0,
        }),
    }}, frame.fence);

    if (self.swapchain.present(vc, vc.queue, frame.command_completed)) |ok| {
        // if ok, frame presented successfully and we should wait for previous frame
        self.frame_index = (self.frame_index + 1) % frames_in_flight;

        const new_frame = self.frames[self.frame_index];

        _ = try vc.device.waitForFences(1, @ptrCast([*]const vk.Fence, &new_frame.fence), vk.TRUE, std.math.maxInt(u64));
        try vc.device.resetFences(1, @ptrCast([*]const vk.Fence, &new_frame.fence));

        return ok;
    } else |err| {
        // if not ok, presentation failure and we should wait for this frame
        _ = try vc.device.waitForFences(1, @ptrCast([*]const vk.Fence, &frame.fence), vk.TRUE, std.math.maxInt(u64));
        try vc.device.resetFences(1, @ptrCast([*]const vk.Fence, &frame.fence));
        return err;
    }
}

const Frame = struct {
    image_acquired: vk.Semaphore,
    command_completed: vk.Semaphore,
    fence: vk.Fence,

    command_pool: vk.CommandPool,
    command_buffer: vk.CommandBuffer,

    query_pool: if (metrics) vk.QueryPool else void,

    fn create(vc: *const VulkanContext) !Frame {
        const image_acquired = try vc.device.createSemaphore(&.{}, null);
        errdefer vc.device.destroySemaphore(image_acquired, null);

        const command_completed = try vc.device.createSemaphore(&.{}, null);
        errdefer vc.device.destroySemaphore(command_completed, null);

        const fence = try vc.device.createFence(&.{
            .flags = .{ .signaled_bit = true },
        }, null);

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

        const query_pool = if (metrics) try vc.device.createQueryPool(&.{
            .query_type = .timestamp,
            .query_count = 2,
        }, null) else undefined;
        errdefer if (metrics) vc.device.destroyQueryPool(query_pool, null);
        if (metrics) vc.device.resetQueryPool(query_pool, 0, 2);

        return Frame {
            .image_acquired = image_acquired,
            .command_completed = command_completed,
            .fence = fence,

            .command_pool = command_pool,
            .command_buffer = command_buffer,

            .query_pool = query_pool,
        };
    }

    fn destroy(self: *Frame, vc: *const VulkanContext) void {
        vc.device.destroySemaphore(self.image_acquired, null);
        vc.device.destroySemaphore(self.command_completed, null);
        vc.device.destroyFence(self.fence, null);
        vc.device.destroyCommandPool(self.command_pool, null);
        if (metrics) vc.device.destroyQueryPool(self.query_pool, null);
    }
};
