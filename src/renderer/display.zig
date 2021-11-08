const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const Window = @import("../utils/Window.zig");
const Swapchain = @import("./Swapchain.zig");
const Images = @import("./Images.zig");
const Commands = @import("./Commands.zig");
const desc = @import("./descriptor.zig");
const Descriptor = desc.Descriptor;
const DestructionQueue = @import("./DestructionQueue.zig");
const utils = @import("./utils.zig");

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

        pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: *std.mem.Allocator, commands: *Commands, initial_extent: vk.Extent2D) !Self {
            var extent = initial_extent;
            var swapchain = try Swapchain.create(vc, allocator, &extent);
            errdefer swapchain.destroy(vc, allocator);

            const display_image_info = Images.ImageCreateRawInfo {
                .extent = extent,
                .usage = .{ .storage_bit = true, .transfer_src_bit = true, },
                .format = .r32g32b32a32_sfloat,
            };
            var display_image = try Images.createRaw(vc, vk_allocator, allocator, &.{ display_image_info });
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
                    .format = .r16_uint,
                }
            };
            var attachment_images = try Images.createRaw(vc, vk_allocator, allocator, &accumulation_image_info);
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

        pub fn startFrame(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: *std.mem.Allocator, commands: *Commands, window: *const Window, descriptor: *Descriptor(num_frames), resized: *bool) !vk.CommandBuffer {
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
                error.OutOfDateKHR => try self.recreate(vc, vk_allocator, allocator, commands, window, resized),
                else => return err,
            };

            try vc.device.resetCommandPool(frame.command_pool, .{});
            try vc.device.beginCommandBuffer(frame.command_buffer, .{
                .flags = .{ .one_time_submit_bit = true },
                .p_inheritance_info = null,
            });

            // transition swapchain to format we can use
            const swap_image_memory_barriers = [_]vk.ImageMemoryBarrier2KHR {
                .{
                    .src_stage_mask = .{},
                    .src_access_mask = .{},
                    .dst_stage_mask = .{ .blit_bit_khr = true, },
                    .dst_access_mask = .{ .transfer_write_bit_khr = true, },
                    .old_layout = .@"undefined",
                    .new_layout = .transfer_dst_optimal,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = self.swapchain.images[self.swapchain.image_index].handle,
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                },
                .{
                    .src_stage_mask = .{},
                    .src_access_mask = .{},
                    .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true, },
                    .dst_access_mask = .{ .shader_storage_write_bit_khr = true, },
                    .old_layout = .@"undefined",
                    .new_layout = .general,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = self.display_image.data.items(.image)[0],
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                },
                .{
                    .src_stage_mask = .{},
                    .src_access_mask = .{},
                    .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true, },
                    .dst_access_mask = .{ .shader_storage_write_bit_khr = true, },
                    .old_layout = .@"undefined",
                    .new_layout = .general,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = self.attachment_images.data.items(.image)[1],
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                },
            };
            vc.device.cmdPipelineBarrier2KHR(frame.command_buffer, vk.DependencyInfoKHR {
                .dependency_flags = .{},
                .memory_barrier_count = 0,
                .p_memory_barriers = undefined,
                .buffer_memory_barrier_count = 0,
                .p_buffer_memory_barriers = undefined,
                .image_memory_barrier_count = swap_image_memory_barriers.len,
                .p_image_memory_barriers = &swap_image_memory_barriers,
            });

            return frame.command_buffer;
        }

        pub fn recreate(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: *std.mem.Allocator, commands: *Commands, window: *const Window, resized: *bool) !void {
            var new_extent = window.getExtent();
            try self.destruction_queue.add(allocator, self.swapchain.handle);
            try self.swapchain.recreate(vc, allocator, &new_extent);
            if (!std.meta.eql(new_extent, self.extent)) {
                resized.* = true;
                self.extent = new_extent;

                try self.destruction_queue.add(allocator, self.display_image);
                self.display_image = try Images.createRaw(vc, vk_allocator, allocator, &[_]Images.ImageCreateRawInfo {
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
                        .format = .r16_uint,
                    }
                };
                self.attachment_images = try Images.createRaw(vc, vk_allocator, allocator, &accumulation_image_info);
                try commands.transitionImageLayout(vc, allocator, self.attachment_images.data.items(.image), .@"undefined", .general);

                comptime var i = 0;
                inline while (i < num_frames) : (i += 1) {
                    self.frames[i].needs_rebind = true;
                }
            }
        }

        pub fn endFrame(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: *std.mem.Allocator, commands: *Commands, window: *const Window, resized: *bool) !void {
            const frame = self.frames[self.frame_index];

            // transition storage image to one we can blit from
            const image_memory_barriers = [_]vk.ImageMemoryBarrier2KHR {
                .{
                    .src_stage_mask = .{ .ray_tracing_shader_bit_khr = true, },
                    .src_access_mask = .{ .shader_storage_write_bit_khr = true, },
                    .dst_stage_mask = .{ .blit_bit_khr = true, },
                    .dst_access_mask = .{ .transfer_write_bit_khr = true, },
                    .old_layout = .general,
                    .new_layout = .transfer_src_optimal,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = self.display_image.data.items(.image)[0],
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                }
            };
            vc.device.cmdPipelineBarrier2KHR(frame.command_buffer, vk.DependencyInfoKHR {
                .dependency_flags = .{},
                .memory_barrier_count = 0,
                .p_memory_barriers = undefined,
                .buffer_memory_barrier_count = 0,
                .p_buffer_memory_barriers = undefined,
                .image_memory_barrier_count = image_memory_barriers.len,
                .p_image_memory_barriers = &image_memory_barriers,
            });

            // blit storage image onto swap image
            const subresource = vk.ImageSubresourceLayers {
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            };

            const region = vk.ImageBlit {
                .src_subresource = subresource,
                .src_offsets = .{
                    .{
                        .x = 0,
                        .y = 0,
                        .z = 0,
                    }, .{
                        .x = @intCast(i32, self.extent.width),
                        .y = @intCast(i32, self.extent.height),
                        .z = 1,
                    }
                },
                .dst_subresource = subresource,
                .dst_offsets = .{
                    .{
                        .x = 0,
                        .y = 0,
                        .z = 0,
                    }, .{
                        .x = @intCast(i32, self.extent.width),
                        .y = @intCast(i32, self.extent.height),
                        .z = 1,
                    },
                },
            };

            vc.device.cmdBlitImage(frame.command_buffer, self.display_image.data.items(.image)[0], .transfer_src_optimal, self.swapchain.images[self.swapchain.image_index].handle, .transfer_dst_optimal, 1, utils.toPointerType(&region), .nearest);

            // transition swapchain back to present mode
            const return_swap_image_memory_barriers = [_]vk.ImageMemoryBarrier2KHR {
                .{
                    .src_stage_mask = .{ .blit_bit_khr = true, },
                    .src_access_mask = .{ .transfer_write_bit_khr = true, },
                    .dst_stage_mask = .{},
                    .dst_access_mask = .{},
                    .old_layout = .transfer_dst_optimal,
                    .new_layout = .present_src_khr,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = self.swapchain.images[self.swapchain.image_index].handle,
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                }
            };
            vc.device.cmdPipelineBarrier2KHR(frame.command_buffer, vk.DependencyInfoKHR {
                .dependency_flags = .{},
                .memory_barrier_count = 0,
                .p_memory_barriers = undefined,
                .buffer_memory_barrier_count = 0,
                .p_buffer_memory_barriers = undefined,
                .image_memory_barrier_count = return_swap_image_memory_barriers.len,
                .p_image_memory_barriers = &return_swap_image_memory_barriers,
            });

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
                try self.recreate(vc, vk_allocator, allocator, commands, window, resized);
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
