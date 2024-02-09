// vulkan allocator
// currently essentially just a passthrough allocator
// functions here are just utilites that help with stuff

const vk = @import("vulkan");
const std = @import("std");
const VulkanContext = @import("../engine.zig").core.VulkanContext;

const Self = @This();

const MemoryStorage = std.ArrayListUnmanaged(vk.DeviceMemory);

memory_type_properties: []vk.MemoryPropertyFlags,
memory: MemoryStorage,

pub fn create(vc: *const VulkanContext, allocator: std.mem.Allocator) !Self {
    const properties = vc.instance.getPhysicalDeviceMemoryProperties(vc.physical_device.handle);

    const memory_type_properties = try allocator.alloc(vk.MemoryPropertyFlags, properties.memory_type_count);
    errdefer allocator.free(memory_type_properties);

    for (properties.memory_types[0..properties.memory_type_count], memory_type_properties) |memory_type, *memory_type_property| {
        memory_type_property.* = memory_type.property_flags;
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


pub fn findMemoryType(self: *const Self, type_filter: u32, properties: vk.MemoryPropertyFlags) !u5 {
    return for (0..self.memory_type_properties.len) |i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and self.memory_type_properties[i].contains(properties)) {
            break @intCast(i);
        }
    } else error.UnavailbleMemoryType;
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

pub fn DeviceBuffer(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info == .Struct and type_info.Struct.layout == .Auto) @compileError("Struct layout of " ++ @typeName(T) ++ " must be specified explicitly, but is not");
    return struct {
        handle: vk.Buffer = .null_handle,

        const BufferSelf = @This();

        pub fn destroy(self: BufferSelf, vc: *const VulkanContext) void {
            vc.device.destroyBuffer(self.handle, null);
        }

        // must've been created with shader device address bit enabled
        pub fn getAddress(self: BufferSelf, vc: *const VulkanContext) vk.DeviceAddress {
            return if (self.handle == .null_handle) 0 else vc.device.getBufferDeviceAddress(&.{
                .buffer = self.handle,
            });
        }

        pub fn is_null(self: BufferSelf) bool {
            return self.handle == .null_handle;
        }

        pub fn sizeInBytes(self: BufferSelf) usize {
            return self.data.len * @sizeOf(T);
        }
    };
}

pub fn createDeviceBuffer(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, comptime T: type, count: vk.DeviceSize, usage: vk.BufferUsageFlags) !DeviceBuffer(T) {
    if (count == 0) return DeviceBuffer(T) {};

    var buffer: vk.Buffer = undefined;
    var memory: vk.DeviceMemory = undefined;
    try self.createRawBuffer(vc, @sizeOf(T) * count, usage, .{ .device_local_bit = true }, &buffer, &memory);

    try self.memory.append(allocator, memory);

    return DeviceBuffer(T) {
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

pub fn HostBuffer(comptime T: type) type {
    return struct {
        handle: vk.Buffer = .null_handle,
        memory: vk.DeviceMemory = .null_handle,
        data: []T = &.{},

        const BufferSelf = @This();

        pub fn destroy(self: BufferSelf, vc: *const VulkanContext) void {
            if (self.handle != .null_handle) {
                vc.device.destroyBuffer(self.handle, null);
                vc.device.unmapMemory(self.memory);
                vc.device.freeMemory(self.memory, null);
            }
        }

        // must've been created with shader device address bit enabled
        pub fn getAddress(self: BufferSelf, vc: *const VulkanContext) vk.DeviceAddress {
            return vc.device.getBufferDeviceAddress(&.{
                .buffer = self.handle,
            });
        }

        pub fn toBytes(self: BufferSelf) HostBuffer(u8) {
            return HostBuffer(u8) {
                .handle = self.handle,
                .memory = self.memory,
                .data = @as([*]u8, @ptrCast(self.data))[0..self.data.len * @sizeOf(T)],
            };
        }

        pub fn sizeInBytes(self: BufferSelf) usize {
            return self.data.len * @sizeOf(T);
        }
    };
}

// count not in bytes, but number of T
pub fn createHostBuffer(self: *Self, vc: *const VulkanContext, comptime T: type, count: vk.DeviceSize, usage: vk.BufferUsageFlags) !HostBuffer(T) {
    if (count == 0) {
        return HostBuffer(T) {
            .handle = .null_handle,
            .memory = .null_handle,
            .data = &.{},
        };
    }

    var buffer: vk.Buffer = undefined;
    var memory: vk.DeviceMemory = undefined;
    const size = @sizeOf(T) * count;
    try self.createRawBuffer(vc, size, usage, .{ .host_visible_bit = true, .host_coherent_bit = true }, &buffer, &memory);

    const data = @as([*]T, @ptrCast(@alignCast((try vc.device.mapMemory(memory, 0, size, .{})).?)))[0..count];

    return HostBuffer(T) {
        .handle = buffer,
        .memory = memory,
        .data = data,
    };
}
