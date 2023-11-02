// abstraction for GPU commands

const std = @import("std");
const vk = @import("vulkan");

const core = @import("./core.zig");
const VulkanContext = core.VulkanContext;
const VkAllocator = core.Allocator;
const vk_helpers = core.vk_helpers;

pool: vk.CommandPool,
buffer: vk.CommandBuffer,

const Self = @This();

pub fn create(vc: *const VulkanContext) !Self {
    const pool = try vc.device.createCommandPool(&.{
        .queue_family_index = vc.physical_device.queue_family_index,
        .flags = .{
            .transient_bit = true,
        },
    }, null);
    errdefer vc.device.destroyCommandPool(pool, null);

    var buffer: vk.CommandBuffer = undefined;
    try vc.device.allocateCommandBuffers(&.{
        .level = vk.CommandBufferLevel.primary,
        .command_pool = pool,
        .command_buffer_count = 1,
    }, @ptrCast(&buffer));

    return Self {
        .pool = pool,
        .buffer = buffer,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    vc.device.destroyCommandPool(self.pool, null);
}

// start recording work
pub fn startRecording(self: *Self, vc: *const VulkanContext) !void {
    try vc.device.beginCommandBuffer(self.buffer, &.{
        .flags = .{
            .one_time_submit_bit = true,
        },
    });
}

// submit recorded work
pub fn submit(self: *Self, vc: *const VulkanContext) !void {
    try vc.device.endCommandBuffer(self.buffer);

    const submit_info = vk.SubmitInfo2 {
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = @ptrCast(&vk.CommandBufferSubmitInfo {
            .command_buffer = self.buffer,
            .device_mask = 0,
        }),
        .wait_semaphore_info_count = 0,
        .p_wait_semaphore_infos = undefined,
        .signal_semaphore_info_count = 0,
        .p_signal_semaphore_infos = undefined,
    };

    try vc.device.queueSubmit2(vc.queue, 1, @ptrCast(&submit_info), .null_handle);
}

pub fn submitAndIdleUntilDone(self: *Self, vc: *const VulkanContext) !void {
    try self.submit(vc);
    try self.idleUntilDone(vc);
}

// must be called at some point if you want a guarantee your work is actually done
pub fn idleUntilDone(self: *Self, vc: *const VulkanContext) !void {
    try vc.device.queueWaitIdle(vc.queue);
    try vc.device.resetCommandPool(self.pool, .{});
}

pub fn copyAccelStructs(self: *Self, vc: *const VulkanContext, infos: []const vk.CopyAccelerationStructureInfoKHR) !void {
    try self.startRecording(vc);
    for (infos) |info| {
        vc.device.cmdCopyAccelerationStructureKHR(self.buffer, &info);
    }
    try self.submitAndIdleUntilDone(vc);
}

pub fn createAccelStructs(self: *Self, vc: *const VulkanContext, geometry_infos: []const vk.AccelerationStructureBuildGeometryInfoKHR, build_infos: []const [*]const vk.AccelerationStructureBuildRangeInfoKHR) !void {
    std.debug.assert(geometry_infos.len == build_infos.len);
    const size: u32 = @intCast(geometry_infos.len);
    try self.startRecording(vc);
    vc.device.cmdBuildAccelerationStructuresKHR(self.buffer, size, geometry_infos.ptr, build_infos.ptr);
    try self.submitAndIdleUntilDone(vc);
}

pub fn createAccelStructsAndGetCompactedSizes(self: *Self, vc: *const VulkanContext, geometry_infos: []const vk.AccelerationStructureBuildGeometryInfoKHR, build_infos: []const [*]const vk.AccelerationStructureBuildRangeInfoKHR, handles: []const vk.AccelerationStructureKHR, compactedSizes: []vk.DeviceSize) !void {
    std.debug.assert(geometry_infos.len == build_infos.len);
    std.debug.assert(build_infos.len == handles.len);
    const size: u32 = @intCast(geometry_infos.len);

    const query_pool = try vc.device.createQueryPool(&.{
        .query_type = .acceleration_structure_compacted_size_khr,
        .query_count = size,
    }, null);
    defer vc.device.destroyQueryPool(query_pool, null);

    vc.device.resetQueryPool(query_pool, 0, size);

    try self.startRecording(vc);

    vc.device.cmdBuildAccelerationStructuresKHR(self.buffer, size, geometry_infos.ptr, build_infos.ptr);

    const barriers = [_]vk.MemoryBarrier2 {
        .{
            .src_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .src_access_mask = .{ .acceleration_structure_write_bit_khr = true },
            .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
            .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true },
        }
    };
    vc.device.cmdPipelineBarrier2(self.buffer, &vk.DependencyInfo {
        .memory_barrier_count = barriers.len,
        .p_memory_barriers = &barriers,
    });

    vc.device.cmdWriteAccelerationStructuresPropertiesKHR(self.buffer, size, handles.ptr, .acceleration_structure_compacted_size_khr, query_pool, 0);

    try self.submitAndIdleUntilDone(vc);

    _ = try vc.device.getQueryPoolResults(query_pool, 0, size, size * @sizeOf(vk.DeviceSize), compactedSizes.ptr, @sizeOf(vk.DeviceSize), .{.@"64_bit" = true, .wait_bit = true });
}

pub fn copyBufferToImage(self: *Self, vc: *const VulkanContext, src: vk.Buffer, dst: vk.Image, width: u32, height: u32, layer_count: u32) !void {
    try self.startRecording(vc);
    
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
    vc.device.cmdCopyBufferToImage(self.buffer, src, dst, .transfer_dst_optimal, 1, @ptrCast(&copy));
    try self.submitAndIdleUntilDone(vc);
}

pub fn transitionImageLayout(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, images: []vk.Image, src_layout: vk.ImageLayout, dst_layout: vk.ImageLayout) !void {
    try self.startRecording(vc);

    const barriers = try allocator.alloc(vk.ImageMemoryBarrier2, images.len);
    defer allocator.free(barriers);
    
    for (images, barriers) |image, *barrier| {
        barrier.* = .{
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

    vc.device.cmdPipelineBarrier2(self.buffer, &vk.DependencyInfo {
        .image_memory_barrier_count = @intCast(barriers.len),
        .p_image_memory_barriers = barriers.ptr,
    });

    try self.submitAndIdleUntilDone(vc);
}

// TODO: possible to ensure all params have same len at comptime?
pub fn uploadDataToImages(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, dst_images: []const vk.Image, src_datas: []const []const u8, extents: []const vk.Extent2D, is_cubemaps: []const bool, dst_layouts: []const vk.ImageLayout) !void {
    std.debug.assert(dst_images.len == src_datas.len);
    std.debug.assert(src_datas.len == extents.len);
    std.debug.assert(extents.len == is_cubemaps.len);

    try self.startRecording(vc);

    const len: u32 = @intCast(dst_images.len);

    const first_barriers = try allocator.alloc(vk.ImageMemoryBarrier2, len);
    defer allocator.free(first_barriers);

    const second_barriers = try allocator.alloc(vk.ImageMemoryBarrier2, len);
    defer allocator.free(second_barriers);

    const staging_buffers = try allocator.alloc(VkAllocator.HostBuffer(u8), len);
    defer allocator.free(staging_buffers);

    defer for (staging_buffers) |staging_buffer| {
        staging_buffer.destroy(vc);
    };

    for (dst_images, first_barriers, second_barriers, dst_layouts, staging_buffers, src_datas) |image, *first_barrier, *second_barrier, dst_layout, *staging_buffer, src_data| {
        first_barrier.* = .{
            .dst_stage_mask = .{ .copy_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined,
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

        second_barrier.* = .{
            .src_stage_mask = .{ .copy_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .transfer_dst_optimal,
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

        staging_buffer.* = try vk_allocator.createHostBuffer(vc, u8, @intCast(src_data.len), .{ .transfer_src_bit = true });
        std.mem.copy(u8, staging_buffer.data, src_data);
    }

    vc.device.cmdPipelineBarrier2(self.buffer, &vk.DependencyInfo {
        .image_memory_barrier_count = len,
        .p_image_memory_barriers = first_barriers.ptr,
    });

    for (dst_images, extents, staging_buffers, is_cubemaps) |image, extent, staging_buffer, is_cubemap| {
        const copy = vk.BufferImageCopy {
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = if (is_cubemap) 6 else 1,
            },
            .image_offset = .{
                .x = 0,
                .y = 0,
                .z = 0,
            },
            .image_extent = .{
                .width = extent.width,
                .height = extent.height,
                .depth = 1,
            },  
        };
        vc.device.cmdCopyBufferToImage(self.buffer, staging_buffer.handle, image, .transfer_dst_optimal, 1, @ptrCast(&copy));
    }

    vc.device.cmdPipelineBarrier2(self.buffer, &vk.DependencyInfo {
        .image_memory_barrier_count = len,
        .p_image_memory_barriers = second_barriers.ptr,
    });

    try self.submitAndIdleUntilDone(vc);
}

// buffers must have appropriate flags
pub fn recordCopyBuffer(self: *Self, vc: *const VulkanContext, dst: vk.Buffer, src: vk.Buffer, regions: []const vk.BufferCopy) void {
    vc.device.cmdCopyBuffer(self.buffer, src, dst, @intCast(regions.len), regions.ptr);
}

// buffers must have appropriate flags
// uploads whole host buffer to gpu buffer
pub fn recordUploadBuffer(self: *Self, comptime T: type, vc: *const VulkanContext, dst: VkAllocator.DeviceBuffer(T), src: VkAllocator.HostBuffer(T)) void {
    const bytes = std.mem.sliceAsBytes(src.data);
    const region = vk.BufferCopy {
        .src_offset = 0,
        .dst_offset = 0,
        .size = bytes.len,
    };

    vc.device.cmdCopyBuffer(self.buffer, src.handle, dst.handle, 1, @ptrCast(&region));
}

pub fn uploadData(self: *Self, comptime T: type, vc: *const VulkanContext, vk_allocator: *VkAllocator, dst: VkAllocator.DeviceBuffer(T), src: []const T) !void {
    const staging_buffer = try vk_allocator.createHostBuffer(vc, T, src.len, .{ .transfer_src_bit = true });
    defer staging_buffer.destroy(vc);

    std.mem.copy(T, staging_buffer.data, src);

    try self.startRecording(vc);
    self.recordUploadBuffer(T, vc, dst, staging_buffer);
    try self.submitAndIdleUntilDone(vc);
}
