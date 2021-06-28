const vk = @import("vulkan");
const std = @import("std");

const VulkanContext = @import("./vulkan_context.zig").VulkanContext;
const Commands = @import("./commands.zig").TransferCommands;

const ModelError = error {
    UnavailbleMemoryType,
};

pub const Model = struct {
    vertex_buffer: vk.Buffer,
    vertex_buffer_memory: vk.DeviceMemory,

    pub fn create(vc: *VulkanContext, commands: *Commands, copy_queue: vk.Queue, vertices: []const u8) !Model {
        var staging_buffer: vk.Buffer = undefined;
        var staging_buffer_memory: vk.DeviceMemory = undefined;
        try createBuffer(vc, vertices.len, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true}, &staging_buffer, &staging_buffer_memory);
        defer vc.device.destroyBuffer(staging_buffer, null);
        defer vc.device.freeMemory(staging_buffer_memory, null);

        const data = (try vc.device.mapMemory(staging_buffer_memory, 0, vertices.len, .{})).?;
        std.mem.copy(u8, @ptrCast([*]u8, data)[0..vertices.len], vertices);
        vc.device.unmapMemory(staging_buffer_memory);

        var vertex_buffer: vk.Buffer = undefined;
        var vertex_buffer_memory: vk.DeviceMemory = undefined;
        try createBuffer(vc, vertices.len, .{ .vertex_buffer_bit = true, .transfer_dst_bit = true}, .{ .device_local_bit = true }, &vertex_buffer, &vertex_buffer_memory);
        errdefer vc.device.destroyBuffer(vertex_buffer, null);
        errdefer vc.device.freeMemory(vertex_buffer_memory, null);

        try commands.copyBuffer(vc, copy_queue, staging_buffer, vertex_buffer, vertices.len);

        return Model {
            .vertex_buffer = vertex_buffer,
            .vertex_buffer_memory = vertex_buffer_memory,
        };
    }

    pub fn destroy(self: *Model, vc: *VulkanContext) void {
        vc.device.destroyBuffer(self.vertex_buffer, null);
        vc.device.freeMemory(self.vertex_buffer_memory, null);
    }
};

fn createBuffer(vc: *const VulkanContext, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, buffer: *vk.Buffer, buffer_memory: *vk.DeviceMemory) !void {
    buffer.* = try vc.device.createBuffer(.{
            .size = size,
            .usage = usage,
            .sharing_mode = vk.SharingMode.exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .flags = .{},
    }, null);
    errdefer vc.device.destroyBuffer(buffer.*, null);

    const mem_requirements = vc.device.getBufferMemoryRequirements(buffer.*);

    buffer_memory.* = try vc.device.allocateMemory(.{
        .allocation_size = mem_requirements.size,
        .memory_type_index = try findMemoryType(vc, mem_requirements.memory_type_bits, properties),
    }, null);
    errdefer vc.device.freeMemory(buffer_memory.*, null);

    try vc.device.bindBufferMemory(buffer.*, buffer_memory.*, 0);
}

fn findMemoryType(vc: *const VulkanContext, type_filter: u32, properties: vk.MemoryPropertyFlags) ModelError!u32 {
    var i: u5 = 0;
    while (i < vc.physical_device.mem_properties.memory_type_count) : (i += 1) {
        if (type_filter & (@as(u32, 1) << i) != 0 and vc.physical_device.mem_properties.memory_types[i].property_flags.contains(properties)) {
            return i;
        }
    }

    return ModelError.UnavailbleMemoryType;
}
