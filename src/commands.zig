const std = @import("std");
const VulkanContext = @import("./VulkanContext.zig");
const Pipeline = @import("./Pipeline.zig");
const Display = @import("./display.zig").Display;
const Scene = @import("./Scene.zig");
const Image = @import("./Image.zig");
const vk = @import("vulkan");
const utils = @import("./utils.zig");

pub fn RenderCommand(comptime frame_count: comptime_int) type {
    return struct {
        pub fn record(vc: *const VulkanContext, buffer: vk.CommandBuffer, pipeline: *const Pipeline, display: *const Display(frame_count), descriptor_sets: *[frame_count]vk.DescriptorSet) !void {
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
                    .image = display.swapchain.images[display.swapchain.image_index].handle,
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
                    .image = display.storage_image.handle,
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                },
            };
            vc.device.cmdPipelineBarrier2KHR(buffer, vk.DependencyInfoKHR {
                .dependency_flags = .{},
                .memory_barrier_count = 0,
                .p_memory_barriers = undefined,
                .buffer_memory_barrier_count = 0,
                .p_buffer_memory_barriers = undefined,
                .image_memory_barrier_count = swap_image_memory_barriers.len,
                .p_image_memory_barriers = &swap_image_memory_barriers,
            });

            // bind our stuff
            vc.device.cmdBindPipeline(buffer, .ray_tracing_khr, pipeline.handle);
            vc.device.cmdBindDescriptorSets(buffer, .ray_tracing_khr, pipeline.layout, 0, 1, @ptrCast([*]vk.DescriptorSet, &descriptor_sets[display.frame_index]), 0, undefined);
            
            // trace rays
            const callable_table = vk.StridedDeviceAddressRegionKHR {
                .device_address = 0,
                .stride = 0,
                .size = 0,
            };

            vc.device.cmdTraceRaysKHR(buffer, pipeline.sbt.getRaygenSBT(vc), pipeline.sbt.getMissSBT(vc), pipeline.sbt.getHitSBT(vc), callable_table, display.extent.width, display.extent.height, 1);

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
                    .image = display.storage_image.handle,
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                }
            };
            vc.device.cmdPipelineBarrier2KHR(buffer, vk.DependencyInfoKHR {
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
                        .x = @intCast(i32, display.extent.width),
                        .y = @intCast(i32, display.extent.height),
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
                        .x = @intCast(i32, display.extent.width),
                        .y = @intCast(i32, display.extent.height),
                        .z = 1,
                    },
                },
            };

            vc.device.cmdBlitImage(buffer, display.storage_image.handle, .transfer_src_optimal, display.swapchain.images[display.swapchain.image_index].handle, .transfer_dst_optimal, 1, @ptrCast([*]const vk.ImageBlit, &region), .nearest);

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
                    .image = display.swapchain.images[display.swapchain.image_index].handle,
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                }
            };
            vc.device.cmdPipelineBarrier2KHR(buffer, vk.DependencyInfoKHR {
                .dependency_flags = .{},
                .memory_barrier_count = 0,
                .p_memory_barriers = undefined,
                .buffer_memory_barrier_count = 0,
                .p_buffer_memory_barriers = undefined,
                .image_memory_barrier_count = return_swap_image_memory_barriers.len,
                .p_image_memory_barriers = &return_swap_image_memory_barriers,
            });
        }
    };
}

pub const ComputeCommands = struct {
    pool: vk.CommandPool,
    buffer: vk.CommandBuffer,

    pub fn create(vc: *const VulkanContext) !ComputeCommands {
        const pool = try vc.device.createCommandPool(.{
            .queue_family_index = vc.physical_device.queue_family_index,
            .flags = .{},
        }, null);
        errdefer vc.device.destroyCommandPool(pool, null);

        var buffer: vk.CommandBuffer = undefined;
        try vc.device.allocateCommandBuffers(.{
            .level = vk.CommandBufferLevel.primary,
            .command_pool = pool,
            .command_buffer_count = 1,
        }, @ptrCast([*]vk.CommandBuffer, &buffer));

        return ComputeCommands {
            .pool = pool,
            .buffer = buffer,
        };
    }

    pub fn destroy(self: *ComputeCommands, vc: *const VulkanContext) void {
        vc.device.freeCommandBuffers(self.pool, 1, @ptrCast([*]vk.CommandBuffer, &self.buffer));
        vc.device.destroyCommandPool(self.pool, null);
    }

    pub fn createAccelStructs(self: *ComputeCommands, vc: *const VulkanContext, geometry_infos: []const vk.AccelerationStructureBuildGeometryInfoKHR, build_infos: []const *const vk.AccelerationStructureBuildRangeInfoKHR) !void {
        std.debug.assert(geometry_infos.len == build_infos.len);

        try vc.device.beginCommandBuffer(self.buffer, .{
            .flags = .{},
            .p_inheritance_info = null,
        });
        vc.device.cmdBuildAccelerationStructuresKHR(self.buffer, @intCast(u32, geometry_infos.len), geometry_infos.ptr, build_infos.ptr);
        try vc.device.endCommandBuffer(self.buffer);

        // todo: do this while doing something else? not factoring out copybuffer and createaccelstruct endings into own function yet
        // because they should be individually optimized
        const submit_info = vk.SubmitInfo2KHR {
            .flags = .{},
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast([*]const vk.CommandBufferSubmitInfoKHR, &vk.CommandBufferSubmitInfoKHR {
                .command_buffer = self.buffer,
                .device_mask = 0,
            }),
            .wait_semaphore_info_count = 0,
            .p_wait_semaphore_infos = undefined,
            .signal_semaphore_info_count = 0,
            .p_signal_semaphore_infos = undefined,
        };

        try vc.device.queueSubmit2KHR(vc.queue, 1, @ptrCast([*]const vk.SubmitInfo2KHR, &submit_info), .null_handle);
        try vc.device.queueWaitIdle(vc.queue);
        try vc.device.resetCommandPool(self.pool, .{});
    }
    
    pub fn uploadData(self: *ComputeCommands, vc: *const VulkanContext, dst_buffer: vk.Buffer, data: []const u8) !void {

        var staging_buffer: vk.Buffer = undefined;
        var staging_buffer_memory: vk.DeviceMemory = undefined;
        try utils.createBuffer(vc, data.len, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true}, &staging_buffer, &staging_buffer_memory);
        defer vc.device.destroyBuffer(staging_buffer, null);
        defer vc.device.freeMemory(staging_buffer_memory, null);

        const dst = (try vc.device.mapMemory(staging_buffer_memory, 0, data.len, .{})).?;
        std.mem.copy(u8, @ptrCast([*]u8, dst)[0..data.len], data);
        vc.device.unmapMemory(staging_buffer_memory);

        try vc.device.beginCommandBuffer(self.buffer, .{
            .flags = .{},
            .p_inheritance_info = null,
        });

        const region = vk.BufferCopy {
            .src_offset = 0,
            .dst_offset = 0,
            .size = data.len,
        };

        vc.device.cmdCopyBuffer(self.buffer, staging_buffer, dst_buffer, 1, @ptrCast([*]const vk.BufferCopy, &region));

        try vc.device.endCommandBuffer(self.buffer);

        const submit_info = vk.SubmitInfo2KHR {
            .flags = .{},
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast([*]const vk.CommandBufferSubmitInfoKHR, &vk.CommandBufferSubmitInfoKHR {
                .command_buffer = self.buffer,
                .device_mask = 0,
            }),
            .wait_semaphore_info_count = 0,
            .p_wait_semaphore_infos = undefined,
            .signal_semaphore_info_count = 0,
            .p_signal_semaphore_infos = undefined,
        };

        try vc.device.queueSubmit2KHR(vc.queue, 1, @ptrCast([*]const vk.SubmitInfo2KHR, &submit_info), .null_handle);
        try vc.device.queueWaitIdle(vc.queue);
        try vc.device.resetCommandPool(self.pool, .{});
    }
};