// vulkan allocator
// currently essentially just a passthrough allocator
// functions here are just utilites that help with stuff

const vk = @import("vulkan");
const std = @import("std");
const VulkanContext = @import("./VulkanContext.zig");

const Self = @This();

const MemoryStorage = std.ArrayListUnmanaged(vk.DeviceMemory);

memory_type_properties: []vk.MemoryPropertyFlags,
memory: MemoryStorage,

pub fn create(vc: *const VulkanContext, allocator: std.mem.Allocator) !Self {
    const properties = vc.instance.getPhysicalDeviceMemoryProperties(vc.physical_device.handle);

    var memory_type_properties = try allocator.alloc(vk.MemoryPropertyFlags, properties.memory_type_count);
    errdefer allocator.free(memory_type_properties);

    for (properties.memory_types[0..properties.memory_type_count]) |memory_type, i| {
        memory_type_properties[i] = memory_type.property_flags;
    }

    return Self {
        .memory_type_properties = memory_type_properties,
        .memory = MemoryStorage {},
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    for (self.memory.items) |memory| {
        vc.device.freeMemory(memory, null);
    }
    self.memory.deinit(allocator);
    allocator.free(self.memory_type_properties);
}

fn createRawBuffer(self: *Self, vc: *const VulkanContext, size: vk.DeviceSize, usage: vk.BufferUsageFlags, properties: vk.MemoryPropertyFlags, buffer: *vk.Buffer, buffer_memory: *vk.DeviceMemory) !void {
    buffer.* = try vc.device.createBuffer(&.{
            .size = size,
            .usage = usage,
            .sharing_mode = vk.SharingMode.exclusive,
    }, null);
    errdefer vc.device.destroyBuffer(buffer.*, null);

    const mem_requirements = vc.device.getBufferMemoryRequirements(buffer.*);

    const allocate_info = vk.MemoryAllocateInfo {
        .allocation_size = mem_requirements.size,
        .memory_type_index = try self.findMemoryType(mem_requirements.memory_type_bits, properties),
        .p_next = if (usage.contains(.{ .shader_device_address_bit = true })) &vk.MemoryAllocateFlagsInfo {
            .device_mask = 0,
            .flags = .{ .device_address_bit = true },
            } else null,
    };

    buffer_memory.* = try vc.device.allocateMemory(&allocate_info, null);
    errdefer vc.device.freeMemory(buffer_memory.*, null);

    try vc.device.bindBufferMemory(buffer.*, buffer_memory.*, 0);
}

pub const DeviceBuffer = struct {
    handle: vk.Buffer,

    pub fn destroy(self: DeviceBuffer, vc: *const VulkanContext) void {
        vc.device.destroyBuffer(self.handle, null);
    }

    // must've been created with shader device address bit enabled
    pub fn getAddress(self: DeviceBuffer, vc: *const VulkanContext) vk.DeviceAddress {
        return vc.device.getBufferDeviceAddress(&.{
            .buffer = self.handle,
        });
    }
};

pub fn createDeviceBuffer(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, size: vk.DeviceSize, usage: vk.BufferUsageFlags) !DeviceBuffer {
    var buffer: vk.Buffer = undefined;
    var memory: vk.DeviceMemory = undefined;
    try self.createRawBuffer(vc, size, usage, .{ .device_local_bit = true }, &buffer, &memory);

    try self.memory.append(allocator, memory);

    return DeviceBuffer {
        .handle = buffer,
    };
}

// buffer that owns it's own memory; good for temp buffers which will quickly be destroyed
pub const OwnedDeviceBuffer = struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,

    pub fn destroy(self: OwnedDeviceBuffer, vc: *const VulkanContext) void {
        vc.device.destroyBuffer(self.handle, null);
        vc.device.freeMemory(self.memory, null);
    }

    // must've been created with shader device address bit enabled
    pub fn getAddress(self: OwnedDeviceBuffer, vc: *const VulkanContext) vk.DeviceAddress {
        return vc.device.getBufferDeviceAddress(&.{
            .buffer = self.handle,
        });
    }
};

pub fn createOwnedDeviceBuffer(self: *Self, vc: *const VulkanContext, size: vk.DeviceSize, usage: vk.BufferUsageFlags) !OwnedDeviceBuffer {
    var buffer: vk.Buffer = undefined;
    var memory: vk.DeviceMemory = undefined;
    try self.createRawBuffer(vc, size, usage, .{ .device_local_bit = true }, &buffer, &memory);

    return OwnedDeviceBuffer {
        .handle = buffer,
        .memory = memory,
    };
}

pub fn findMemoryType(self: *const Self, type_filter: u32, properties: vk.MemoryPropertyFlags) !u32 {
    var i: u5 = 0;
    while (i < self.memory_type_properties.len) : (i += 1) {
        if (type_filter & (@as(u32, 1) << i) != 0 and self.memory_type_properties[i].contains(properties)) {
            return i;
        }
    }

    return error.UnavailbleMemoryType;
}

pub fn HostBuffer(comptime T: type) type {
    return struct {
        handle: vk.Buffer,
        memory: vk.DeviceMemory,
        data: []T,

        const BufferSelf = @This();

        pub fn destroy(self: BufferSelf, vc: *const VulkanContext) void {
            vc.device.destroyBuffer(self.handle, null);
            vc.device.unmapMemory(self.memory);
            vc.device.freeMemory(self.memory, null);
        }

        // must've been created with shader device address bit enabled
        pub fn getAddress(self: BufferSelf, vc: *const VulkanContext) vk.DeviceAddress {
            return vc.device.getBufferDeviceAddress(&.{
                .buffer = self.handle,
            });
        }
    };
}

// count not in bytes, but number of T
pub fn createHostBuffer(self: *Self, vc: *const VulkanContext, comptime T: type, count: u32, usage: vk.BufferUsageFlags) !HostBuffer(T) {
    var buffer: vk.Buffer = undefined;
    var memory: vk.DeviceMemory = undefined;
    const size = @sizeOf(T) * count;
    try self.createRawBuffer(vc, size, usage, .{ .host_visible_bit = true, .host_coherent_bit = true }, &buffer, &memory);

    const data = @ptrCast([*]T, @alignCast(@alignOf([*]T), (try vc.device.mapMemory(memory, 0, size, .{})).?))[0..count];

    return HostBuffer(T) {
        .handle = buffer,
        .memory = memory,
        .data = data,
    };
}
