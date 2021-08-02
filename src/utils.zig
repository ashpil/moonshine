const vk = @import("vulkan");
const std = @import("std");
const VulkanContext = @import("./vulkan_context.zig");

const Error = error {
    UnavailbleMemoryType,
};

pub fn createBuffer(vc: *const VulkanContext, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, buffer: *vk.Buffer, buffer_memory: *vk.DeviceMemory) !void {
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
        .p_next = if (usage.contains(.{ .shader_device_address_bit = true })) &vk.MemoryAllocateFlagsInfo {
            .device_mask = 0,
            .flags = .{ .device_address_bit = true },
            } else null,
    }, null);
    errdefer vc.device.freeMemory(buffer_memory.*, null);

    try vc.device.bindBufferMemory(buffer.*, buffer_memory.*, 0);
}

pub fn findMemoryType(vc: *const VulkanContext, type_filter: u32, properties: vk.MemoryPropertyFlags) Error!u32 {
    var i: u5 = 0;
    while (i < vc.physical_device.mem_properties.memory_type_count) : (i += 1) {
        if (type_filter & (@as(u32, 1) << i) != 0 and vc.physical_device.mem_properties.memory_types[i].property_flags.contains(properties)) {
            return i;
        }
    }

    return Error.UnavailbleMemoryType;
}
