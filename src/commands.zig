const std = @import("std");
const VulkanContext = @import("./vulkan_context.zig").VulkanContext;
const Pipeline = @import("./pipeline.zig").RaytracingPipeline;
const vk = @import("vulkan");

pub const RenderCommands = struct {
    allocator: *std.mem.Allocator,

    pool: vk.CommandPool,
    buffers: []vk.CommandBuffer,

    pub fn create(vc: *VulkanContext, allocator: *std.mem.Allocator, pipeline: *Pipeline, num_buffers: usize) !RenderCommands {
        const pool = try vc.device.createCommandPool(.{
            .queue_family_index = vc.physical_device.queue_families.compute,
            .flags = .{},
        }, null);
        errdefer vc.device.destroyCommandPool(pool, null);

        var buffers = try allocator.alloc(vk.CommandBuffer, num_buffers);
        try vc.device.allocateCommandBuffers(.{
            .level = vk.CommandBufferLevel.primary,
            .command_pool = pool,
            .command_buffer_count = @intCast(u32, buffers.len),
        }, buffers.ptr);

        for (buffers) |buffer| {
            try vc.device.beginCommandBuffer(buffer, .{
                .flags = .{},
                .p_inheritance_info = null,
            });
            
            vc.device.cmdBindPipeline(buffer, .ray_tracing_khr, pipeline.handle);
            //vc.device.cmdBindDescriptorSets(buffer, .ray_tracing_khr, pipeline.layout, 0, 0, undefined, 0, undefined);
        }

        return RenderCommands {
            .allocator = allocator,

            .pool = pool,
            .buffers = buffers,
        };
    }

    pub fn destroy(self: *RenderCommands, vc: *VulkanContext) void {
        vc.device.freeCommandBuffers(self.pool, @intCast(u32, self.buffers.len), self.buffers.ptr);
        self.allocator.free(self.buffers);
        vc.device.destroyCommandPool(self.pool, null);
    }
};

pub const TransferCommands = struct {
    pool: vk.CommandPool,
    buffer: vk.CommandBuffer,

    pub fn create(vc: *VulkanContext) !TransferCommands {
        const pool = try vc.device.createCommandPool(.{
            .queue_family_index = vc.physical_device.queue_families.compute,
            .flags = .{},
        }, null);
        errdefer vc.device.destroyCommandPool(pool, null);

        var buffer: vk.CommandBuffer = undefined;
        try vc.device.allocateCommandBuffers(.{
            .level = vk.CommandBufferLevel.primary,
            .command_pool = pool,
            .command_buffer_count = 1,
        }, @ptrCast([*]vk.CommandBuffer, &buffer));

        return TransferCommands {
            .pool = pool,
            .buffer = buffer,
        };
    }

    pub fn destroy(self: *TransferCommands, vc: *VulkanContext) void {
        vc.device.freeCommandBuffers(self.pool, 1, @ptrCast([*]vk.CommandBuffer, &self.buffer));
        vc.device.destroyCommandPool(self.pool, null);
    }

    pub fn copyBuffer(self: *TransferCommands, vc: *VulkanContext, queue: vk.Queue, src: vk.Buffer, dst: vk.Buffer, size: vk.DeviceSize) !void {
        try vc.device.beginCommandBuffer(self.buffer, .{
            .flags = .{},
            .p_inheritance_info = null,
        });

        const region = vk.BufferCopy {
            .src_offset = 0,
            .dst_offset = 0,
            .size = size,
        };
        vc.device.cmdCopyBuffer(self.buffer, src, dst, 1, @ptrCast([*]const vk.BufferCopy, &region));

        try vc.device.endCommandBuffer(self.buffer);

        const submit_info = vk.SubmitInfo {
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.buffer),
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
        };

        try vc.device.queueSubmit(queue, 1, @ptrCast([*]const vk.SubmitInfo, &submit_info), .null_handle);

        try vc.device.queueWaitIdle(queue);
    }
};
