const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./vulkan_context.zig");
const Window = @import("./window.zig");
const Swapchain = @import("./swapchain.zig");
const Image = @import("./image.zig");
const RenderCommand = @import("./commands.zig").RenderCommand;

pub fn Display(comptime num_frames: comptime_int) type {
    return struct {
        const Self = @This();

        swapchain: Swapchain,
        storage_image: Image,
        frames: [num_frames]Frame,
        frame_index: u8,

        extent: vk.Extent2D,

        pub fn create(vc: *const VulkanContext, allocator: *std.mem.Allocator, initial_extent: vk.Extent2D) !Self {
            var extent = initial_extent;
            const swapchain = try Swapchain.create(vc, allocator, &extent);
            const storage_image = try Image.create(vc, extent, .{ .storage_bit = true, .transfer_src_bit = true });
            
            var frames: [num_frames]Frame = undefined;
            comptime var i = 0;
            inline while (i < num_frames) : (i += 1) {
                frames[i] = try Frame.create(vc);
            }

            return Self {
                .swapchain = swapchain,
                .storage_image = storage_image,
                .frames = frames,
                .frame_index = 0,

                .extent = extent,
            };
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator) void {
            self.storage_image.destroy(vc);
            self.swapchain.destroy(vc, allocator);
            comptime var i = 0;
            inline while (i < num_frames) : (i += 1) {
                self.frames[i].destroy(vc);
            }
        }

        // todo: change this to sync2
        pub fn startFrame(self: *Self, vc: *const VulkanContext) !vk.CommandBuffer {
            const frame = self.frames[self.frame_index];

            _ = try vc.device.waitForFences(1, @ptrCast([*]const vk.Fence, &frame.fence), vk.TRUE, std.math.maxInt(u64));
            try vc.device.resetFences(1, @ptrCast([*]const vk.Fence, &frame.fence));
            try self.swapchain.acquireNextImage(vc, frame.image_acquired);

            try vc.device.resetCommandPool(frame.command_pool, .{});
            try vc.device.beginCommandBuffer(frame.command_buffer, .{
                .flags = .{ .one_time_submit_bit = true },
                .p_inheritance_info = null,
            });

            return frame.command_buffer;
        }

        pub fn endFrame(self: *Self, vc: *const VulkanContext) !void {
            const frame = self.frames[self.frame_index];

            try vc.device.endCommandBuffer(frame.command_buffer);

            try vc.device.queueSubmit(vc.compute_queue, 1, &[_]vk.SubmitInfo { .{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &frame.image_acquired),
                .p_wait_dst_stage_mask = &[_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }},
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &frame.command_buffer),
                .signal_semaphore_count = 1,
                .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &frame.command_completed),
            }}, frame.fence);

            try self.swapchain.present(vc, vc.present_queue, frame.command_completed);

            self.frame_index = (self.frame_index + 1) % num_frames;
        }

        const Frame = struct {
            image_acquired: vk.Semaphore,
            command_completed: vk.Semaphore,
            fence: vk.Fence,
            command_pool: vk.CommandPool,
            command_buffer: vk.CommandBuffer,

            fn create(vc: *const VulkanContext) !Frame {
                const image_acquired = try vc.device.createSemaphore(.{
                    .flags = .{},
                }, null);

                const command_completed = try vc.device.createSemaphore(.{
                    .flags = .{},
                }, null);

                const fence = try vc.device.createFence(.{
                    .flags = .{ .signaled_bit = true },
                }, null);

                const command_pool = try vc.device.createCommandPool(.{
                    .queue_family_index = vc.physical_device.queue_families.compute,
                    .flags = .{ .transient_bit = true },
                }, null);

                var command_buffer: vk.CommandBuffer = undefined;
                try vc.device.allocateCommandBuffers(.{
                    .level = vk.CommandBufferLevel.primary,
                    .command_pool = command_pool,
                    .command_buffer_count = 1,
                }, @ptrCast([*]vk.CommandBuffer, &command_buffer));

                return Frame {
                    .image_acquired = image_acquired,
                    .command_completed = command_completed,
                    .fence = fence,

                    .command_pool = command_pool,
                    .command_buffer = command_buffer,
                };
            }

            fn destroy(self: *Frame, vc: *const VulkanContext) void {
                vc.device.destroySemaphore(self.image_acquired, null);
                vc.device.destroySemaphore(self.command_completed, null);
                vc.device.destroyFence(self.fence, null);
                vc.device.destroyCommandPool(self.command_pool, null);
            }
        };
    };
}
