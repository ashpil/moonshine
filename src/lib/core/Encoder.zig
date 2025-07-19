// abstraction for GPU commands.
// the intent is that you only create a couple of these as they're not super lightweight and have a lot of conveniences
// TODO: this could be made a little more type-safe by splitting encoder states into their own types,
// e.g., PendingEncoder, ActiveEncoder, etc

const std = @import("std");
const vk = @import("vulkan");

const core = @import("./core.zig");
const VulkanContext = core.VulkanContext;
const vk_helpers = core.vk_helpers;

pool: vk.CommandPool,
buffer: VulkanContext.CommandBuffer,
destruction_queue: core.DestructionQueue, // use the page allocator for this for now -- the idea that you probably will either want to destroy zero or many
upload_allocator: core.mem.UploadPageAllocator,
upload_arena: std.heap.ArenaAllocator, // can't use State as we want to return the allocator but maintain a reference to it

const Self = @This();

pub fn create(vc: *const VulkanContext, name: [*:0]const u8) !Self {
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
    }, (&buffer)[0..1]);

    try vk_helpers.setDebugName(vc.device, buffer, name);

    return Self {
        .pool = pool,
        .buffer = VulkanContext.CommandBuffer.init(buffer, vc.device_dispatch),
        .destruction_queue = .{},
        .upload_allocator = core.mem.UploadPageAllocator.init(vc),
        .upload_arena = std.heap.ArenaAllocator {
            .child_allocator = undefined,
            .state = .{},
        },
    };
}

pub fn uploadAllocator(self: *Self) std.mem.Allocator {
    self.upload_arena.child_allocator = self.upload_allocator.allocator();
    return self.upload_arena.allocator();
}

// command buffer must not be pending
pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    vc.device.destroyCommandPool(self.pool, null);
    self.destruction_queue.destroy(vc, std.heap.page_allocator);
}

// attach resource to the lifetime of this encoder, to be destroyed
// when the encoder is no longer active
// the annoying bit about this is that it makes destruction (or delayed destruction)
// failable due to the allocation. perhaps one should need to allocate this upfront?
// you should need to know the maximum number of resources you might destroy on encoder begin
pub fn attachResource(self: *Self, resource: anytype) !void {
    try self.destruction_queue.append(std.heap.page_allocator, resource);
}

pub fn clearResources(self: *Self, vc: *const VulkanContext) void {
    self.destruction_queue.clear(vc);

    self.upload_arena.child_allocator = self.upload_allocator.allocator();
    std.debug.assert(self.upload_arena.reset(.free_all));
}

// start recording work
pub fn begin(self: Self) !void {
    try self.buffer.beginCommandBuffer(&.{
        .flags = .{
            .one_time_submit_bit = true,
        },
    });
}

// submit recorded work
pub fn submit(self: Self, queue: VulkanContext.Queue, sync: struct {
    wait_semaphore_infos: []const vk.SemaphoreSubmitInfoKHR = &.{},
    signal_semaphore_infos: []const vk.SemaphoreSubmitInfoKHR = &.{},
    fence: vk.Fence = .null_handle,
}) !void {
    try self.buffer.endCommandBuffer();

    const submit_info = vk.SubmitInfo2 {
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = (&vk.CommandBufferSubmitInfo {
            .command_buffer = self.buffer.handle,
            .device_mask = 0,
        })[0..1],
        .wait_semaphore_info_count = @intCast(sync.wait_semaphore_infos.len),
        .p_wait_semaphore_infos = sync.wait_semaphore_infos.ptr,
        .signal_semaphore_info_count = @intCast(sync.signal_semaphore_infos.len),
        .p_signal_semaphore_infos = sync.signal_semaphore_infos.ptr,
    };

    try queue.submit2(1, (&submit_info)[0..1], sync.fence);
}

pub fn submitAndIdleUntilDone(self: *Self, vc: *const VulkanContext) !void {
    try self.submit(vc.queue, .{});
    try vc.queue.waitIdle();
    try vc.device.resetCommandPool(self.pool, .{});
    self.clearResources(vc);
}

pub fn uploadDataToImage(self: Self, comptime T: type, src_data: core.mem.BufferSlice(T), dst_image: vk.Image, dst_image_extent: vk.Extent2D, dst_layout: vk.ImageLayout) void {
    self.buffer.pipelineBarrier2(&vk.DependencyInfo {
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = (&vk.ImageMemoryBarrier2 {
            .dst_stage_mask = .{ .copy_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = dst_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
        })[0..1],
    });
    self.copyBufferToImage(src_data.handle, src_data.offset, dst_image, .transfer_dst_optimal, dst_image_extent);
    self.buffer.pipelineBarrier2(&vk.DependencyInfo {
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = (&vk.ImageMemoryBarrier2 {
            .src_stage_mask = .{ .copy_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = dst_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = dst_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
        })[0..1],
    });
}

// buffers must have appropriate flags
pub fn copyBuffer(self: Self, src: vk.Buffer, dst: vk.Buffer, regions: []const vk.BufferCopy) void {
    self.buffer.copyBuffer(src, dst, @intCast(regions.len), regions.ptr);
}

// size in number of data to duplicate, not bytes
pub fn fillBuffer(self: Self, dst: vk.Buffer, size: vk.DeviceSize, data: anytype) void {
    if (@sizeOf(@TypeOf(data)) != 4) @compileError("fill buffer requires data to be 4 bytes");
    self.buffer.fillBuffer(dst, 0, size * 4, @bitCast(data));
}

pub fn clearColorImage(self: Self, dst: vk.Image, layout: vk.ImageLayout, color: vk.ClearColorValue) void {
    self.buffer.clearColorImage(dst, layout, &color, 1, &[1]vk.ImageSubresourceRange{
        .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = vk.REMAINING_MIP_LEVELS,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        }
    });
}

pub fn buildAccelerationStructures(self: Self, infos: []const vk.AccelerationStructureBuildGeometryInfoKHR, build_range_infos: []const [*]const vk.AccelerationStructureBuildRangeInfoKHR) void {
    std.debug.assert(infos.len == build_range_infos.len);
    self.buffer.buildAccelerationStructuresKHR(@intCast(infos.len), infos.ptr, build_range_infos.ptr);
}

pub fn copyImageToBuffer(self: Self, src: vk.Image, layout: vk.ImageLayout, extent: vk.Extent2D, dst: vk.Buffer) void {
    const copy = vk.BufferImageCopy {
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
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
    self.buffer.copyImageToBuffer(src, layout, dst, 1, (&copy)[0..1]);
}

pub fn copyBufferToImage(self: Self, src: vk.Buffer, src_offset: vk.DeviceSize, dst: vk.Image, layout: vk.ImageLayout, extent: vk.Extent2D) void {
    const copy = vk.BufferImageCopy {
        .buffer_offset = src_offset,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
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
    self.buffer.copyBufferToImage(src, dst, layout, 1, (&copy)[0..1]);
}

// meant to be same as vk.ImageMemoryBarrier2 but sane defaults
pub const ImageBarrier = extern struct {
    s_type: vk.StructureType = .image_memory_barrier_2,
    p_next: ?*const anyopaque = null,
    src_stage_mask: vk.PipelineStageFlags2 = .{},
    src_access_mask: vk.AccessFlags2 = .{},
    dst_stage_mask: vk.PipelineStageFlags2 = .{},
    dst_access_mask: vk.AccessFlags2 = .{},
    // https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/VkImageMemoryBarrier2.html
    // > When the old and new layout are equal, the layout values are ignored - data is preserved
    // > no matter what values are specified, or what layout the image is currently in.
    old_layout: vk.ImageLayout = .general,
    new_layout: vk.ImageLayout = .general,
    src_queue_family_index: u32 = vk.QUEUE_FAMILY_IGNORED,
    dst_queue_family_index: u32 = vk.QUEUE_FAMILY_IGNORED,
    image: vk.Image,

    aspect_mask: vk.ImageAspectFlags = .{ .color_bit = true },
    base_mip_level: u32 = 0,
    level_count: u32 = vk.REMAINING_MIP_LEVELS,
    base_array_layer: u32 = 0,
    layer_count: u32 = vk.REMAINING_ARRAY_LAYERS,
};

// meant to be same as vk.BufferMemoryBarrier2 but sane defaults
pub const BufferBarrier = extern struct {
    s_type: vk.StructureType = .buffer_memory_barrier_2,
    p_next: ?*const anyopaque = null,
    src_stage_mask: vk.PipelineStageFlags2 = .{},
    src_access_mask: vk.AccessFlags2 = .{},
    dst_stage_mask: vk.PipelineStageFlags2 = .{},
    dst_access_mask: vk.AccessFlags2 = .{},
    src_queue_family_index: u32 = vk.QUEUE_FAMILY_IGNORED,
    dst_queue_family_index: u32 = vk.QUEUE_FAMILY_IGNORED,
    buffer: vk.Buffer,
    offset: vk.DeviceSize = 0,
    size: vk.DeviceSize = vk.WHOLE_SIZE,
};

comptime {
    std.debug.assert(@sizeOf(ImageBarrier) == @sizeOf(vk.ImageMemoryBarrier2));
    std.debug.assert(@sizeOf(BufferBarrier) == @sizeOf(vk.BufferMemoryBarrier2));
}

pub fn barrier(self: Self, images: []const ImageBarrier, buffers: []const BufferBarrier) void {
    self.buffer.pipelineBarrier2(&vk.DependencyInfo {
        .image_memory_barrier_count = @intCast(images.len),
        .p_image_memory_barriers = @ptrCast(images.ptr),
        .buffer_memory_barrier_count = @intCast(buffers.len),
        .p_buffer_memory_barriers = @ptrCast(buffers.ptr),
    });
}

pub fn global_barrier(self: Self) void {
    self.buffer.pipelineBarrier2(&vk.DependencyInfo {
        .memory_barrier_count = 1,
        .p_memory_barriers = (&vk.MemoryBarrier2 {
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
        })[0..1]
    });
}
