const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const Window = @import("../Window.zig");
const Swapchain = @import("./Swapchain.zig");
const ImageManager = @import("./ImageManager.zig");
const Commands = @import("./Commands.zig");
const DescriptorLayout = @import("./descriptor.zig").OutputDescriptorLayout;
const DestructionQueue = @import("./DestructionQueue.zig");
const utils = @import("./utils.zig");

const measure_perf = @import("build_options").vk_measure_perf;

pub fn Display(comptime num_frames: comptime_int) type {
    return struct {
        const Self = @This();

        frames: [num_frames]Frame,
        frame_index: u8,

        swapchain: Swapchain,
        images: ImageManager, // 2 images -- first is display image, second is accumulation image; TODO: display image may not be needed on some platforms where the swapchain can be used as a storage image

        render_extent: vk.Extent2D,

        destruction_queue: DestructionQueue,

        set: vk.DescriptorSet,

        // uses initial_extent as the render extent -- that is, the buffer that is actually being rendered into, irrespective of window size
        // then during rendering the render buffer is blitted into the swapchain images
        pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, descriptor_layout: *const DescriptorLayout, initial_extent: vk.Extent2D) !Self {
            var swapchain = try Swapchain.create(vc, allocator, initial_extent);
            errdefer swapchain.destroy(vc, allocator);

            var images = try ImageManager.createRaw(vc, vk_allocator, allocator, &.{
                .{
                    .extent = initial_extent,
                    .usage = .{ .storage_bit = true, .transfer_src_bit = true, },
                    .format = .r32g32b32a32_sfloat,
                },
                .{
                    .extent = initial_extent,
                    .usage = .{ .storage_bit = true, },
                    .format = .r32g32b32a32_sfloat,
                },
            });
            errdefer images.destroy(vc, allocator);
            try commands.transitionImageLayout(vc, allocator, images.data.items(.handle)[1..], .@"undefined", .general);

            const set = try descriptor_layout.allocate_set(vc, [_]vk.WriteDescriptorSet {
                vk.WriteDescriptorSet {
                    .dst_set = undefined,
                    .dst_binding = 0,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_image,
                    .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                        .sampler = .null_handle,
                        .image_view = images.data.items(.view)[0],
                        .image_layout = .general,
                    }),
                    .p_buffer_info = undefined,
                    .p_texel_buffer_view = undefined,
                },
                vk.WriteDescriptorSet {
                    .dst_set = undefined,
                    .dst_binding = 1,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_image,
                    .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                        .sampler = .null_handle,
                        .image_view = images.data.items(.view)[1],
                        .image_layout = .general,
                    }),
                    .p_buffer_info = undefined,
                    .p_texel_buffer_view = undefined,
                },
            });

            var frames: [num_frames]Frame = undefined;
            comptime var i = 0;
            inline while (i < num_frames) : (i += 1) {
                frames[i] = try Frame.create(vc);
            }

            return Self {
                .swapchain = swapchain,
                .frames = frames,
                .frame_index = 0,

                .images = images,

                .render_extent = initial_extent,

                // TODO: need to clean this every once in a while since we're only allowed a limited amount of most types of handles
                .destruction_queue = DestructionQueue.create(),

                .set = set,
            };
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
            self.images.destroy(vc, allocator);
            self.swapchain.destroy(vc, allocator);
            comptime var i = 0;
            inline while (i < num_frames) : (i += 1) {
                self.frames[i].destroy(vc);
            }
            self.destruction_queue.destroy(vc, allocator);
        }

        pub fn startFrame(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, window: *const Window) !vk.CommandBuffer {
            const frame = self.frames[self.frame_index];

            _ = try vc.device.waitForFences(1, @ptrCast([*]const vk.Fence, &frame.fence), vk.TRUE, std.math.maxInt(u64));
            try vc.device.resetFences(1, @ptrCast([*]const vk.Fence, &frame.fence));

            if (measure_perf) {
                var timestamps: [2]u64 = undefined;
                const result = try vc.device.getQueryPoolResults(frame.query_pool, 0, 2, 2 * @sizeOf(u64), &timestamps, @sizeOf(u64), .{.@"64_bit" = true });
                const time = (@intToFloat(f64, timestamps[1] - timestamps[0]) * vc.physical_device.properties.limits.timestamp_period) / 1_000_000.0;
                std.debug.print("{}: {d}\n", .{result, time});
                vc.device.resetQueryPool(frame.query_pool, 0, 2);
            }

            // we can optionally handle swapchain recreation on suboptimal here,
            // but I think for some reason it's better to just do it after presentation
            while (true) {
                if (self.swapchain.acquireNextImage(vc, frame.image_acquired)) |_| break else |err| switch (err) {
                    error.OutOfDateKHR => try self.recreate(vc, allocator, window),
                    else => return err,
                }
            }

            try vc.device.resetCommandPool(frame.command_pool, .{});
            try vc.device.beginCommandBuffer(frame.command_buffer, &.{
                .flags = .{ .one_time_submit_bit = true },
                .p_inheritance_info = null,
            });

            if (measure_perf) vc.device.cmdWriteTimestamp2(frame.command_buffer, .{ .top_of_pipe_bit = true }, frame.query_pool, 0);

            // transition swapchain to format we can use
            const swap_image_memory_barriers = [_]vk.ImageMemoryBarrier2 {
                .{
                    .src_stage_mask = .{},
                    .src_access_mask = .{},
                    .dst_stage_mask = .{ .blit_bit = true, },
                    .dst_access_mask = .{ .transfer_write_bit = true, },
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
                    .dst_access_mask = .{ .shader_storage_write_bit = true, },
                    .old_layout = .@"undefined",
                    .new_layout = .general,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = self.images.data.items(.handle)[0],
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                },
            };
            vc.device.cmdPipelineBarrier2(frame.command_buffer, &vk.DependencyInfo {
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

        pub fn recreate(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, window: *const Window) !void {
            try self.destruction_queue.add(allocator, self.swapchain.handle);
            try self.swapchain.recreate(vc, allocator, window.getExtent());
        }

        pub fn endFrame(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, window: *const Window) !void {
            const frame = self.frames[self.frame_index];

            // transition storage image to one we can blit from
            const image_memory_barriers = [_]vk.ImageMemoryBarrier2 {
                .{
                    .src_stage_mask = .{ .ray_tracing_shader_bit_khr = true, },
                    .src_access_mask = .{ .shader_storage_write_bit = true, },
                    .dst_stage_mask = .{ .blit_bit = true, },
                    .dst_access_mask = .{ .transfer_write_bit = true, },
                    .old_layout = .general,
                    .new_layout = .transfer_src_optimal,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = self.images.data.items(.handle)[0],
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                }
            };
            vc.device.cmdPipelineBarrier2(frame.command_buffer, &vk.DependencyInfo {
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
                        .x = @intCast(i32, self.render_extent.width),
                        .y = @intCast(i32, self.render_extent.height),
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
                        .x = @intCast(i32, self.swapchain.extent.width),
                        .y = @intCast(i32, self.swapchain.extent.height),
                        .z = 1,
                    },
                },
            };

            vc.device.cmdBlitImage(frame.command_buffer, self.images.data.items(.handle)[0], .transfer_src_optimal, self.swapchain.images[self.swapchain.image_index].handle, .transfer_dst_optimal, 1, utils.toPointerType(&region), .nearest);

            // transition swapchain back to present mode
            const return_swap_image_memory_barriers = [_]vk.ImageMemoryBarrier2 {
                .{
                    .src_stage_mask = .{ .blit_bit = true, },
                    .src_access_mask = .{ .transfer_write_bit = true, },
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
            vc.device.cmdPipelineBarrier2(frame.command_buffer, &vk.DependencyInfo {
                .dependency_flags = .{},
                .memory_barrier_count = 0,
                .p_memory_barriers = undefined,
                .buffer_memory_barrier_count = 0,
                .p_buffer_memory_barriers = undefined,
                .image_memory_barrier_count = return_swap_image_memory_barriers.len,
                .p_image_memory_barriers = &return_swap_image_memory_barriers,
            });

            if (measure_perf) vc.device.cmdWriteTimestamp2(frame.command_buffer, .{ .bottom_of_pipe_bit = true }, frame.query_pool, 1);

            try vc.device.endCommandBuffer(frame.command_buffer);

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
                if (ok == vk.Result.suboptimal_khr) {
                    try self.recreate(vc, allocator, window);
                }
            } else |err| {
                if (err == error.OutOfDateKHR) {
                    try self.recreate(vc, allocator, window);
                }
                return err;
            }

            self.frame_index = (self.frame_index + 1) % num_frames;
        }

        const Frame = struct {
            image_acquired: vk.Semaphore,
            command_completed: vk.Semaphore,
            fence: vk.Fence,

            command_pool: vk.CommandPool,
            command_buffer: vk.CommandBuffer,

            query_pool: if (measure_perf) vk.QueryPool else void,

            fn create(vc: *const VulkanContext) !Frame {
                const image_acquired = try vc.device.createSemaphore(&.{
                    .flags = .{},
                }, null);
                errdefer vc.device.destroySemaphore(image_acquired, null);

                const command_completed = try vc.device.createSemaphore(&.{
                    .flags = .{},
                }, null);
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

                const query_pool = if (measure_perf) try vc.device.createQueryPool(&.{
                    .flags = .{},
                    .query_type = .timestamp,
                    .query_count = 2,
                    .pipeline_statistics = .{},
                }, null) else undefined;
                errdefer if (measure_perf) vc.device.destroyQueryPool(query_pool, null);
                if (measure_perf) vc.device.resetQueryPool(query_pool, 0, 2);

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
                if (measure_perf) vc.device.destroyQueryPool(self.query_pool, null);
            }
        };
    };
}
