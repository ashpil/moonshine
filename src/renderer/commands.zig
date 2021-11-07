const std = @import("std");
const VulkanContext = @import("./VulkanContext.zig");
const Pipeline = @import("./Pipeline.zig");
const Display = @import("./display.zig").Display;
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
                    .image = display.display_image.data.items(.image)[0],
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
            vc.device.cmdBindDescriptorSets(buffer, .ray_tracing_khr, pipeline.layout, 0, 1, utils.toPointerType(&descriptor_sets[display.frame_index]), 0, undefined);
            
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
                    .image = display.display_image.data.items(.image)[0],
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

            vc.device.cmdBlitImage(buffer, display.display_image.data.items(.image)[0], .transfer_src_optimal, display.swapchain.images[display.swapchain.image_index].handle, .transfer_dst_optimal, 1, utils.toPointerType(&region), .nearest);

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
        vc.device.freeCommandBuffers(self.pool, 1, utils.toPointerType(&self.buffer));
        vc.device.destroyCommandPool(self.pool, null);
    }

    fn beginOneTimeCommands(self: *ComputeCommands, vc: *const VulkanContext) !void {
        try vc.device.beginCommandBuffer(self.buffer, .{
            .flags = .{},
            .p_inheritance_info = null,
        });
    }

    fn endOneTimeCommands(self: *ComputeCommands, vc: *const VulkanContext) !void {
        try vc.device.endCommandBuffer(self.buffer);

        const submit_info = vk.SubmitInfo2KHR {
            .flags = .{},
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = utils.toPointerType(&vk.CommandBufferSubmitInfoKHR {
                .command_buffer = self.buffer,
                .device_mask = 0,
            }),
            .wait_semaphore_info_count = 0,
            .p_wait_semaphore_infos = undefined,
            .signal_semaphore_info_count = 0,
            .p_signal_semaphore_infos = undefined,
        };

        try vc.device.queueSubmit2KHR(vc.queue, 1, utils.toPointerType(&submit_info), .null_handle);
        try vc.device.queueWaitIdle(vc.queue);
        try vc.device.resetCommandPool(self.pool, .{});
    }

    pub fn copyAccelStructs(self: *ComputeCommands, vc: *const VulkanContext, infos: []const vk.CopyAccelerationStructureInfoKHR) !void {
        try self.beginOneTimeCommands(vc);
        for (infos) |info| {
            vc.device.cmdCopyAccelerationStructureKHR(self.buffer, info);
        }
        try self.endOneTimeCommands(vc);
    }

    pub fn createAccelStructs(self: *ComputeCommands, vc: *const VulkanContext, geometry_infos: []const vk.AccelerationStructureBuildGeometryInfoKHR, build_infos: []const *const vk.AccelerationStructureBuildRangeInfoKHR) !void {
        std.debug.assert(geometry_infos.len == build_infos.len);
        const size = @intCast(u32, geometry_infos.len);
        try self.beginOneTimeCommands(vc);
        vc.device.cmdBuildAccelerationStructuresKHR(self.buffer, size, geometry_infos.ptr, build_infos.ptr);
        try self.endOneTimeCommands(vc);
    }

    pub fn createAccelStructsAndGetCompactedSizes(self: *ComputeCommands, vc: *const VulkanContext, geometry_infos: []const vk.AccelerationStructureBuildGeometryInfoKHR, build_infos: []const *const vk.AccelerationStructureBuildRangeInfoKHR, handles: []const vk.AccelerationStructureKHR, compactedSizes: []vk.DeviceSize) !void {
        std.debug.assert(geometry_infos.len == build_infos.len);
        std.debug.assert(build_infos.len == handles.len);
        const size = @intCast(u32, geometry_infos.len);


        const query_pool = try vc.device.createQueryPool(.{
            .flags = .{},
            .query_type = .acceleration_structure_compacted_size_khr,
            .query_count = size,
            .pipeline_statistics = .{},
        }, null);
        defer vc.device.destroyQueryPool(query_pool, null);

        vc.device.resetQueryPool(query_pool, 0, size);

        try self.beginOneTimeCommands(vc);

        vc.device.cmdBuildAccelerationStructuresKHR(self.buffer, size, geometry_infos.ptr, build_infos.ptr);

        const barriers = [_]vk.MemoryBarrier2KHR {
            .{
                .src_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
                .src_access_mask = .{ .acceleration_structure_write_bit_khr = true },
                .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
                .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true },
            }
        };
        vc.device.cmdPipelineBarrier2KHR(self.buffer, vk.DependencyInfoKHR {
            .dependency_flags = .{},
            .memory_barrier_count = barriers.len,
            .p_memory_barriers = &barriers,
            .buffer_memory_barrier_count = 0,
            .p_buffer_memory_barriers = undefined,
            .image_memory_barrier_count = 0,
            .p_image_memory_barriers = undefined,
        });

        vc.device.cmdWriteAccelerationStructuresPropertiesKHR(self.buffer, size, handles.ptr, .acceleration_structure_compacted_size_khr, query_pool, 0);

        try self.endOneTimeCommands(vc);

        _ = try vc.device.getQueryPoolResults(query_pool, 0, size, size * @sizeOf(vk.DeviceSize), compactedSizes.ptr, @sizeOf(vk.DeviceSize), .{.@"64_bit" = true, .wait_bit = true });
    }

    pub fn copyBufferToImage(self: *ComputeCommands, vc: *const VulkanContext, src: vk.Buffer, dst: vk.Image, width: u32, height: u32, layer_count: u32) !void {
        try self.beginOneTimeCommands(vc);
        
        const copy = vk.BufferImageCopy {
            .buffer_offset = 0,
            .buffer_row_length = width,
            .buffer_image_height = height,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = layer_count,
            },
            .image_offset = .{
                .x = 0,
                .y = 0,
                .z = 0,
            },
            .image_extent = .{
                .width = width,
                .height = height,
                .depth = 1,
            },  
        };
        vc.device.cmdCopyBufferToImage(self.buffer, src, dst, .transfer_dst_optimal, 1, utils.toPointerType(&copy));
        try self.endOneTimeCommands(vc);
    }

    pub fn transitionImageLayout(self: *ComputeCommands, vc: *const VulkanContext, allocator: *std.mem.Allocator, images: []vk.Image, src_layout: vk.ImageLayout, dst_layout: vk.ImageLayout) !void {
        try self.beginOneTimeCommands(vc);

        const barriers = try allocator.alloc(vk.ImageMemoryBarrier2KHR, images.len);
        defer allocator.free(barriers);
        
        for (images) |image, i| {
            barriers[i] = .{
                .src_stage_mask = .{},
                .src_access_mask = .{},
                .dst_stage_mask = .{},
                .dst_access_mask = .{},
                .old_layout = src_layout,
                .new_layout = dst_layout,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = image,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            };
        }

        vc.device.cmdPipelineBarrier2KHR(self.buffer, vk.DependencyInfoKHR {
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = undefined,
            .buffer_memory_barrier_count = 0,
            .p_buffer_memory_barriers = undefined,
            .image_memory_barrier_count = @intCast(u32, barriers.len),
            .p_image_memory_barriers = barriers.ptr,
        });

        try self.endOneTimeCommands(vc);
    }

    // TODO: possible to ensure all params have same len at comptime?
    pub fn uploadDataToImages(self: *ComputeCommands, vc: *const VulkanContext, allocator: *std.mem.Allocator, dst_images: []vk.Image, src_datas: [][]const u8, sizes: []u64, extents: []vk.Extent2D, is_cubemaps: []bool) !void {
        std.debug.assert(dst_images.len == src_datas.len);
        std.debug.assert(src_datas.len == sizes.len);
        std.debug.assert(sizes.len == extents.len);
        std.debug.assert(extents.len == is_cubemaps.len);

        try self.beginOneTimeCommands(vc);

        const len = @intCast(u32, dst_images.len);

        const first_barriers = try allocator.alloc(vk.ImageMemoryBarrier2KHR, len);
        defer allocator.free(first_barriers);

        const second_barriers = try allocator.alloc(vk.ImageMemoryBarrier2KHR, len);
        defer allocator.free(second_barriers);

        const staging_buffers = try allocator.alloc(vk.Buffer, len);
        defer allocator.free(staging_buffers);

        const staging_buffers_memory = try allocator.alloc(vk.DeviceMemory, len);
        defer allocator.free(staging_buffers_memory);

        for (dst_images) |image, i| {
            first_barriers[i] = .{
                .src_stage_mask = .{},
                .src_access_mask = .{},
                .dst_stage_mask = .{ .copy_bit_khr = true },
                .dst_access_mask = .{ .transfer_write_bit_khr = true },
                .old_layout = .@"undefined",
                .new_layout = .transfer_dst_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = image,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            };

            second_barriers[i] = .{
                .src_stage_mask = .{ .copy_bit_khr = true },
                .src_access_mask = .{ .transfer_write_bit_khr = true },
                .dst_stage_mask = .{},
                .dst_access_mask = .{},
                .old_layout = .transfer_dst_optimal,
                .new_layout = .shader_read_only_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = image,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            };

            try utils.createBuffer(vc, sizes[i], .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &staging_buffers[i], &staging_buffers_memory[i]);

            const dst = @ptrCast([*]u8, (try vc.device.mapMemory(staging_buffers_memory[i], 0, sizes[i], .{})).?)[0..sizes[i]];
            std.mem.copy(u8, dst, src_datas[i]);
            vc.device.unmapMemory(staging_buffers_memory[i]);
        }

        defer for (staging_buffers_memory) |_, j| {
            defer vc.device.destroyBuffer(staging_buffers[j], null);
            defer vc.device.freeMemory(staging_buffers_memory[j], null);
        };

        vc.device.cmdPipelineBarrier2KHR(self.buffer, vk.DependencyInfoKHR {
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = undefined,
            .buffer_memory_barrier_count = 0,
            .p_buffer_memory_barriers = undefined,
            .image_memory_barrier_count = len,
            .p_image_memory_barriers = first_barriers.ptr,
        });

        for (dst_images) |image, i| {
            const copy = vk.BufferImageCopy {
                .buffer_offset = 0,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = if (is_cubemaps[i]) 6 else 1,
                },
                .image_offset = .{
                    .x = 0,
                    .y = 0,
                    .z = 0,
                },
                .image_extent = .{
                    .width = extents[i].width,
                    .height = extents[i].height,
                    .depth = 1,
                },  
            };
            vc.device.cmdCopyBufferToImage(self.buffer, staging_buffers[i], image, .transfer_dst_optimal, 1, utils.toPointerType(&copy));
        }

        vc.device.cmdPipelineBarrier2KHR(self.buffer, vk.DependencyInfoKHR {
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = undefined,
            .buffer_memory_barrier_count = 0,
            .p_buffer_memory_barriers = undefined,
            .image_memory_barrier_count = len,
            .p_image_memory_barriers = second_barriers.ptr,
        });

        try self.endOneTimeCommands(vc);
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

        try self.beginOneTimeCommands(vc);

        const region = vk.BufferCopy {
            .src_offset = 0,
            .dst_offset = 0,
            .size = data.len,
        };

        vc.device.cmdCopyBuffer(self.buffer, staging_buffer, dst_buffer, 1, utils.toPointerType(&region));
        try self.endOneTimeCommands(vc);
    }
};