const std = @import("std");
const VulkanContext = @import("./vulkan_context.zig").VulkanContext;
const Pipeline = @import("./pipeline.zig").RaytracingPipeline;
const vk = @import("vulkan");
const utils = @import("./utils.zig");

pub fn RenderCommands(comptime comp_vc: *VulkanContext, comptime comp_allocator: *std.mem.Allocator) type {
    return struct {
        allocator: *std.mem.Allocator,

        pool: vk.CommandPool,
        buffers: []vk.CommandBuffer,
        queue: vk.Queue,

        const Self = @This();

        const vc = comp_vc;
        const allocator = comp_allocator;

        pub fn create(pipeline: *Pipeline(comp_vc), num_buffers: usize, queue_index: u32) !Self {
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

            const queue = vc.device.getDeviceQueue(vc.physical_device.queue_families.compute, queue_index);

            return Self {
                .allocator = allocator,

                .pool = pool,
                .buffers = buffers,
                .queue = queue,
            };
        }

        pub fn destroy(self: *Self) void {
            vc.device.freeCommandBuffers(self.pool, @intCast(u32, self.buffers.len), self.buffers.ptr);
            allocator.free(self.buffers);
            vc.device.destroyCommandPool(self.pool, null);
        }
    };
}

pub fn ComputeCommands(comptime comp_vc: *VulkanContext) type {
    return struct {
        pool: vk.CommandPool,
        buffer: vk.CommandBuffer,
        queue: vk.Queue,

        const Self = @This();

        const vc = comp_vc;

        pub fn create(queue_index: u32) !Self {
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

            return Self {
                .pool = pool,
                .buffer = buffer,
                .queue = queue,
            };
        }

        pub fn destroy(self: *Self) void {
            vc.device.freeCommandBuffers(self.pool, 1, @ptrCast([*]vk.CommandBuffer, &self.buffer));
            vc.device.destroyCommandPool(self.pool, null);
        }

        pub fn createAccelStructs(self: *Self, geometry_info: []const vk.AccelerationStructureBuildGeometryInfoKHR, build_infos: []*const vk.AccelerationStructureBuildRangeInfoKHR) !void {
            try vc.device.beginCommandBuffer(self.buffer, .{
                .flags = .{},
                .p_inheritance_info = null,
            });
            vc.device.cmdBuildAccelerationStructuresKHR(self.buffer, @intCast(u32, geometry_info.len), geometry_info.ptr, build_infos.ptr);
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
        
        pub fn uploadData(self: *Self, dst_buffer: vk.Buffer, data: []const u8) !void {

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
}
