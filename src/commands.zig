const std = @import("std");
const VulkanContext = @import("./vulkan_context.zig");
const Pipeline = @import("./pipeline.zig");
const Swapchain = @import("./swapchain.zig");
const Scene = @import("./scene.zig");
const Image = @import("./image.zig");
const DescriptorSet = @import("./descriptor_set.zig");
const vk = @import("vulkan");
const utils = @import("./utils.zig");

pub const RenderCommands = struct {
    buffer_pool: vk.CommandPool,
    buffers: []vk.CommandBuffer,

    queue: vk.Queue,

    pub fn create(vc: *const VulkanContext, allocator: *std.mem.Allocator, pipeline: *const Pipeline, image: *const Image, swapchain: *const Swapchain, descriptor_sets: *const DescriptorSet, queue_index: u32) !RenderCommands {
        const num_buffers = @intCast(u32, swapchain.images.len);

        const buffer_pool = try vc.device.createCommandPool(.{
            .queue_family_index = vc.physical_device.queue_families.compute,
            .flags = .{},
        }, null);
        errdefer vc.device.destroyCommandPool(buffer_pool, null);

        var buffers = try allocator.alloc(vk.CommandBuffer, num_buffers);
        try vc.device.allocateCommandBuffers(.{
            .level = vk.CommandBufferLevel.primary,
            .command_pool = buffer_pool,
            .command_buffer_count = num_buffers,
        }, buffers.ptr);

        for (buffers) |buffer, i| {
            try vc.device.beginCommandBuffer(buffer, .{
                .flags = .{},
                .p_inheritance_info = null,
            });
            
            vc.device.cmdBindPipeline(buffer, .ray_tracing_khr, pipeline.handle);
            vc.device.cmdBindDescriptorSets(buffer, .ray_tracing_khr, pipeline.layout, 0, 1, @ptrCast([*]vk.DescriptorSet, &descriptor_sets.sets[i]), 0, undefined);

            // const raygen_table = vk.StridedDeviceAddressRegionKHR {

            // };
            // const miss_table = vk.StridedDeviceAddressRegionKHR {

            // };
            // const hit_table = vk.StridedDeviceAddressRegionKHR {

            // };
            // const callable_table = vk.StridedDeviceAddressRegionKHR {

            // };
            // vc.device.cmdTraceRaysKHR(buffer, &raygen_table, &miss_table, &hit_table, &callable_table, swapchain.extent.width, swapchain.extent.height, 1);
            _ = image;
            // const subresource = vk.ImageSubresourceLayers {
            //     .aspect_mask = .{ .color_bit = true },
            //     .mip_level = 0,
            //     .base_array_layer = 0,
            //     .layer_count = 1,
            // };
            // const offset = vk.Offset3D {
            //     .x = 0,
            //     .y = 0,
            //     .z = 0,
            // };
            // const region = vk.ImageCopy {
            //     .src_subresource = subresource,
            //     .src_offset = offset,
            //     .dst_subresource = subresource,
            //     .dst_offset = offset,
            //     .extent = .{
            //         .width = swapchain.extent.width,
            //         .height = swapchain.extent.height,
            //         .depth = 1,
            //     },
            // };
            // vc.device.cmdCopyImage(buffer, image.handle, .transfer_src_optimal, swapchain.images[i].handle, .present_src_khr, 1, @ptrCast([*]const vk.ImageCopy, &region));

            try vc.device.endCommandBuffer(buffer);
        }

        const queue = vc.device.getDeviceQueue(vc.physical_device.queue_families.compute, queue_index);

        return RenderCommands {
            .buffer_pool = buffer_pool,
            .buffers = buffers,
            .queue = queue,
        };
    }

    pub fn destroy(self: *RenderCommands, vc: *const VulkanContext, allocator: *std.mem.Allocator,) void {
        allocator.free(self.buffers);
        vc.device.destroyCommandPool(self.buffer_pool, null);
    }
};

pub const ComputeCommands = struct {
    pool: vk.CommandPool,
    buffer: vk.CommandBuffer,
    queue: vk.Queue,

    pub fn create(vc: *const VulkanContext, queue_index: u32) !ComputeCommands {
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

        const queue = vc.device.getDeviceQueue(vc.physical_device.queue_families.compute, queue_index);

        return ComputeCommands {
            .pool = pool,
            .buffer = buffer,
            .queue = queue,
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
        const submit_info = vk.SubmitInfo {
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.buffer),
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
        };

        try vc.device.queueSubmit(self.queue, 1, @ptrCast([*]const vk.SubmitInfo, &submit_info), .null_handle);
        try vc.device.queueWaitIdle(self.queue);
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

        const submit_info = vk.SubmitInfo {
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.buffer),
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
        };

        try vc.device.queueSubmit(self.queue, 1, @ptrCast([*]const vk.SubmitInfo, &submit_info), .null_handle);
        try vc.device.queueWaitIdle(self.queue);
        try vc.device.resetCommandPool(self.pool, .{});
    }
};