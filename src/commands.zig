const std = @import("std");
const VulkanContext = @import("./vulkan_context.zig");
const Pipeline = @import("./pipeline.zig").RaytracingPipeline;
const vk = @import("vulkan");
const utils = @import("./utils.zig");

pub fn RenderCommands(comptime comp_vc: *VulkanContext, comptime comp_allocator: *std.mem.Allocator) type {
    return struct {
        allocator: *std.mem.Allocator,

        buffer_pool: vk.CommandPool,
        buffers: []vk.CommandBuffer,

        descriptor_pool: vk.DescriptorPool,

        queue: vk.Queue,

        const Self = @This();

        const vc = comp_vc;
        const allocator = comp_allocator;

        pub fn create(pipeline: *const Pipeline(comp_vc), num_buffers: u32, queue_index: u32) !Self {

            // allocate command buffers
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

            // allocate descriptor sets
            const descriptor_pool = try vc.device.createDescriptorPool(.{
                .flags = .{},
                .max_sets = num_buffers,
                .pool_size_count = 2,
                .p_pool_sizes = &[_]vk.DescriptorPoolSize {
                    .{
                        .type_ = .acceleration_structure_khr,
                        .descriptor_count = 1,
                    },
                    .{
                        .type_ = .storage_image,
                        .descriptor_count = 1,
                    },
                },
            }, null);

            const descriptor_set_layouts = try allocator.alloc(vk.DescriptorSetLayout, num_buffers);
            defer allocator.free(descriptor_set_layouts);

            for (descriptor_set_layouts) |*layout| {
                layout.* = pipeline.descriptor_set_layout;
            }

            var descriptor_sets = try allocator.alloc(vk.DescriptorSet, num_buffers);
            defer allocator.free(descriptor_sets);
            try vc.device.allocateDescriptorSets(.{
                .descriptor_pool = descriptor_pool,
                .descriptor_set_count = num_buffers,
                .p_set_layouts = descriptor_set_layouts.ptr,
            }, descriptor_sets.ptr);

            for (buffers) |buffer, i| {
                try vc.device.beginCommandBuffer(buffer, .{
                    .flags = .{},
                    .p_inheritance_info = null,
                });
                
                vc.device.cmdBindPipeline(buffer, .ray_tracing_khr, pipeline.handle);
                vc.device.cmdBindDescriptorSets(buffer, .ray_tracing_khr, pipeline.layout, 0, 1, @ptrCast([*]vk.DescriptorSet, &descriptor_sets[i]), 0, undefined);

                try vc.device.endCommandBuffer(buffer);
            }

            const queue = vc.device.getDeviceQueue(vc.physical_device.queue_families.compute, queue_index);

            return Self {
                .allocator = allocator,

                .buffer_pool = buffer_pool,
                .buffers = buffers,
                .queue = queue,

                .descriptor_pool = descriptor_pool,
            };
        }

        pub fn destroy(self: *Self) void {
            vc.device.freeCommandBuffers(self.buffer_pool, @intCast(u32, self.buffers.len), self.buffers.ptr);
            allocator.free(self.buffers);
            vc.device.destroyCommandPool(self.buffer_pool, null);

            vc.device.destroyDescriptorPool(self.descriptor_pool, null);
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

        pub fn createAccelStructs(self: *Self, geometry_infos: []const vk.AccelerationStructureBuildGeometryInfoKHR, build_infos: []const *const vk.AccelerationStructureBuildRangeInfoKHR) !void {
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
