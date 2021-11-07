const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const Window = @import("../utils/Window.zig");
const Swapchain = @import("./Swapchain.zig");
const Images = @import("./Images.zig");
const TransferCommands = @import("./commands.zig").ComputeCommands;
const desc = @import("./descriptor.zig");
const Descriptor = desc.Descriptor;
const DestructionQueue = @import("./DestructionQueue.zig");

pub fn Display(comptime num_frames: comptime_int) type {
    return struct {
        const Self = @This();

        frames: [num_frames]Frame,
        frame_index: u8,

        swapchain: Swapchain,
        display_image: Images,
        attachment_images: Images,

        extent: vk.Extent2D,

        destruction_queue: DestructionQueue,

        pub fn create(vc: *const VulkanContext, allocator: *std.mem.Allocator, commands: *TransferCommands, initial_extent: vk.Extent2D) !Self {
            var extent = initial_extent;
            var swapchain = try Swapchain.create(vc, allocator, &extent);
            errdefer swapchain.destroy(vc, allocator);

            const display_image_info = Images.ImageCreateRawInfo {
                .extent = extent,
                .usage = .{ .storage_bit = true, .transfer_src_bit = true, },
                .format = .r32g32b32a32_sfloat,
            };
            var display_image = try Images.createRaw(vc, allocator, &.{ display_image_info });
            errdefer display_image.destroy(vc, allocator);

            const accumulation_image_info = [_]Images.ImageCreateRawInfo {
                .{
                    .extent = extent,
                    .usage = .{ .storage_bit = true, },
                    .format = .r32g32b32a32_sfloat,
                },
                .{
                    .extent = extent,
                    .usage = .{ .storage_bit = true, .transfer_src_bit = true, },
                    .format = .r8_uint,
                }
            };
            var attachment_images = try Images.createRaw(vc, allocator, &accumulation_image_info);
            errdefer attachment_images.destroy(vc, allocator);
            try commands.transitionImageLayout(vc, allocator, attachment_images.data.items(.image), .@"undefined", .general);

            var frames: [num_frames]Frame = undefined;
            comptime var i = 0;
            inline while (i < num_frames) : (i += 1) {
                frames[i] = try Frame.create(vc);
            }

            return Self {
                .swapchain = swapchain,
                .frames = frames,
                .frame_index = 0,

                .display_image = display_image,
                .attachment_images = attachment_images,

                .extent = extent,

                // TODO: need to clean this every once in a while since we're only allowed a limited amount of most types of handles
                .destruction_queue = DestructionQueue.create(),
            };
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator) void {
            self.display_image.destroy(vc, allocator);
            self.attachment_images.destroy(vc, allocator);
            self.swapchain.destroy(vc, allocator);
            comptime var i = 0;
            inline while (i < num_frames) : (i += 1) {
                self.frames[i].destroy(vc);
            }
            self.destruction_queue.destroy(vc, allocator);
        }

        pub fn startFrame(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator, commands: *TransferCommands, window: *const Window, descriptor: *Descriptor(num_frames), resized: *bool) !vk.CommandBuffer {
            const frame = self.frames[self.frame_index];

            _ = try vc.device.waitForFences(1, @ptrCast([*]const vk.Fence, &frame.fence), vk.TRUE, std.math.maxInt(u64));
            try vc.device.resetFences(1, @ptrCast([*]const vk.Fence, &frame.fence));

            if (frame.needs_rebind) {
                const attachment_views = self.attachment_images.data.items(.view);
                try descriptor.write(vc, allocator, .{ 0, 1, 2 }, .{ self.frame_index }, [_]desc.StorageImage {
                    desc.StorageImage {
                        .view = self.display_image.data.items(.view)[0],
                    },
                    desc.StorageImage {
                        .view = attachment_views[0],
                    },
                    desc.StorageImage {
                        .view = attachment_views[1],
                    }
                });
                self.frames[self.frame_index].needs_rebind = false;
            }

            // we can optionally handle swapchain recreation on suboptimal here,
            // but I think for some reason it's better to just do it after presentation
            _ = self.swapchain.acquireNextImage(vc, frame.image_acquired) catch |err| switch (err) {
                error.OutOfDateKHR => try self.recreate(vc, allocator, commands, window, resized),
                else => return err,
            };

            try vc.device.resetCommandPool(frame.command_pool, .{});
            try vc.device.beginCommandBuffer(frame.command_buffer, .{
                .flags = .{ .one_time_submit_bit = true },
                .p_inheritance_info = null,
            });

            return frame.command_buffer;
        }

        pub fn recreate(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator, commands: *TransferCommands, window: *const Window, resized: *bool) !void {
            var new_extent = window.getExtent();
            try self.destruction_queue.add(allocator, self.swapchain.handle);
            try self.swapchain.recreate(vc, allocator, &new_extent);
            if (!std.meta.eql(new_extent, self.extent)) {
                resized.* = true;
                self.extent = new_extent;

                try self.destruction_queue.add(allocator, self.display_image);
                self.display_image = try Images.createRaw(vc, allocator, &[_]Images.ImageCreateRawInfo {
                    .{
                        .extent = self.extent,
                        .usage = .{ .storage_bit = true, .transfer_src_bit = true, },
                        .format = .r32g32b32a32_sfloat,
                    }
                });

                try self.destruction_queue.add(allocator, self.attachment_images);
                const accumulation_image_info = [_]Images.ImageCreateRawInfo {
                    .{
                        .extent = self.extent,
                        .usage = .{ .storage_bit = true, },
                        .format = .r32g32b32a32_sfloat,
                    },
                    .{
                        .extent = self.extent,
                        .usage = .{ .storage_bit = true, .transfer_src_bit = true, },
                        .format = .r8_uint,
                    }
                };
                self.attachment_images = try Images.createRaw(vc, allocator, &accumulation_image_info);
                try commands.transitionImageLayout(vc, allocator, self.attachment_images.data.items(.image), .@"undefined", .general);

                comptime var i = 0;
                inline while (i < num_frames) : (i += 1) {
                    self.frames[i].needs_rebind = true;
                }
            }
        }

        pub fn endFrame(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator, commands: *TransferCommands, window: *const Window, resized: *bool) !void {
            const frame = self.frames[self.frame_index];

            try vc.device.endCommandBuffer(frame.command_buffer);

            try vc.device.queueSubmit2KHR(vc.queue, 1, &[_]vk.SubmitInfo2KHR { .{
                .flags = .{},
                .wait_semaphore_info_count = 1,
                .p_wait_semaphore_infos = @ptrCast([*]const vk.SemaphoreSubmitInfoKHR, &vk.SemaphoreSubmitInfoKHR{
                    .semaphore = frame.image_acquired,
                    .value = 0,
                    .stage_mask = .{ .color_attachment_output_bit_khr = true },
                    .device_index = 0,
                }),
                .command_buffer_info_count = 1,
                .p_command_buffer_infos = @ptrCast([*]const vk.CommandBufferSubmitInfoKHR, &vk.CommandBufferSubmitInfoKHR {
                    .command_buffer = frame.command_buffer,
                    .device_mask = 0,
                }),
                .signal_semaphore_info_count = 1,
                .p_signal_semaphore_infos = @ptrCast([*]const vk.SemaphoreSubmitInfoKHR, &vk.SemaphoreSubmitInfoKHR {
                    .semaphore = frame.command_completed,
                    .value = 0,
                    .stage_mask =  .{ .color_attachment_output_bit_khr = true },
                    .device_index = 0,
                }),
            }}, frame.fence);

            const present_result = self.swapchain.present(vc, vc.queue, frame.command_completed) catch |err| switch (err) {
                error.OutOfDateKHR => vk.Result.suboptimal_khr,
                else => return err,
            };

            if (present_result == .suboptimal_khr) {
                try self.recreate(vc, allocator, commands, window, resized);
            }

            self.frame_index = (self.frame_index + 1) % num_frames;
        }

        const Frame = struct {
            image_acquired: vk.Semaphore,
            command_completed: vk.Semaphore,
            fence: vk.Fence,

            needs_rebind: bool,

            command_pool: vk.CommandPool,
            command_buffer: vk.CommandBuffer,

            fn create(vc: *const VulkanContext) !Frame {
                const image_acquired = try vc.device.createSemaphore(.{
                    .flags = .{},
                }, null);
                errdefer vc.device.destroySemaphore(image_acquired, null);

                const command_completed = try vc.device.createSemaphore(.{
                    .flags = .{},
                }, null);
                errdefer vc.device.destroySemaphore(command_completed, null);

                const fence = try vc.device.createFence(.{
                    .flags = .{ .signaled_bit = true },
                }, null);

                const command_pool = try vc.device.createCommandPool(.{
                    .queue_family_index = vc.physical_device.queue_family_index,
                    .flags = .{ .transient_bit = true },
                }, null);
                errdefer vc.device.destroyCommandPool(command_pool, null);

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

                    .needs_rebind = false,

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
