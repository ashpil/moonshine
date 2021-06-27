const VulkanContext = @import("./vulkan_context.zig").VulkanContext;
const vk = @import("vulkan");

// possible optimization: use multiple queues
pub const Commands = struct {
    compute_queue: vk.Queue,

    transfer_pool: vk.CommandPool,
    transfer_buffer: vk.CommandBuffer,

    pub fn create(vc: *VulkanContext) !Commands {
        const transfer_pool = try vc.device.createCommandPool(.{
            .queue_family_index = vc.physical_device.queue_families.compute,
            .flags = .{},
        }, null);
        errdefer vc.device.destroyCommandPool(transfer_pool, null);

        var transfer_buffer: vk.CommandBuffer = undefined;
        try vc.device.allocateCommandBuffers(.{
            .level = vk.CommandBufferLevel.primary,
            .command_pool = transfer_pool,
            .command_buffer_count = 1,
        }, @ptrCast([*]vk.CommandBuffer, &transfer_buffer));
        errdefer vc.device.freeCommandBuffers(transfer_pool, 1, @ptrCast([*]vk.CommandBuffer, &transfer_buffer));

        const compute_queue = vc.device.getDeviceQueue(vc.physical_device.queue_families.compute, 0);

        return Commands {
            .compute_queue = compute_queue,
            .transfer_pool = transfer_pool,
            .transfer_buffer = transfer_buffer,
        };
    }

    pub fn destroy(self: *Commands, vc: *VulkanContext) void {
        vc.device.freeCommandBuffers(self.transfer_pool, 1, @ptrCast([*]vk.CommandBuffer, &self.transfer_buffer));
        vc.device.destroyCommandPool(self.transfer_pool, null);
    }

    pub fn copyBuffer(self: *Commands, vc: *VulkanContext, src: vk.Buffer, dst: vk.Buffer, size: vk.DeviceSize) !void {
        try vc.device.beginCommandBuffer(self.transfer_buffer, .{
            .flags = .{},
            .p_inheritance_info = null,
        });

        const region = vk.BufferCopy {
            .src_offset = 0,
            .dst_offset = 0,
            .size = size,
        };
        vc.device.cmdCopyBuffer(self.transfer_buffer, src, dst, 1, @ptrCast([*]const vk.BufferCopy, &region));

        try vc.device.endCommandBuffer(self.transfer_buffer);

        const submit_info = vk.SubmitInfo {
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.transfer_buffer),
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
        };

        try vc.device.queueSubmit(self.compute_queue, 1, @ptrCast([*]const vk.SubmitInfo, &submit_info), .null_handle);

        try vc.device.queueWaitIdle(self.compute_queue);
    }
};
