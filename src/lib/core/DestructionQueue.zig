const std = @import("std");
const vk = @import("vulkan");

const core = @import("./core.zig");
const VulkanContext = core.VulkanContext;
const DeviceBuffer = core.Allocator.DeviceBuffer;

// type erased Vulkan object
const Destruction = struct {
    object_type: vk.ObjectType,
    destroyee: u64,

    fn destroy(self: Destruction, vc: *const VulkanContext) void {
        switch (self.object_type) {
            .swapchain_khr => if (comptime @hasField(VulkanContext.Device.Wrapper.Dispatch, "vkDestroySwapchainKHR")) vc.device.destroySwapchainKHR(@enumFromInt(self.destroyee), null) else unreachable,
            .pipeline_layout => vc.device.destroyPipelineLayout(@enumFromInt(self.destroyee), null),
            .pipeline => vc.device.destroyPipeline(@enumFromInt(self.destroyee), null),
            .buffer => vc.device.destroyBuffer(@enumFromInt(self.destroyee), null),
            .image_view => vc.device.destroyImageView(@enumFromInt(self.destroyee), null),
            .image => vc.device.destroyImage(@enumFromInt(self.destroyee), null),
            .device_memory => vc.device.freeMemory(@enumFromInt(self.destroyee), null),
            .acceleration_structure_khr => vc.device.destroyAccelerationStructureKHR(@enumFromInt(self.destroyee), null),
            else => unreachable, // TODO
        }
    }
};

// TODO: this should be an SoA type of thing like list((tag, list(union)))
queue: std.ArrayListUnmanaged(Destruction) = .empty,

const Self = @This();

// works on any type exclusively made up of Vulkan objects and primitives
pub fn append(self: *Self, allocator: std.mem.Allocator, item: anytype) !void {
    const T = @TypeOf(item);

    if (comptime @typeInfo(T) == .@"struct") {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (field.type != void and @typeInfo(field.type) != .int) {
                try self.append(allocator, @field(item, field.name));
            }
        }
    } else {
        try self.queue.append(allocator, Destruction {
            .object_type = comptime core.vk_helpers.typeToObjectType(T),
            .destroyee = @intFromEnum(item),
        });
    }
}

pub fn clear(self: *Self, vc: *const VulkanContext) void {
    for (self.queue.items) |*item| item.destroy(vc);
    self.queue.clearRetainingCapacity();
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.clear(vc);
    self.queue.deinit(allocator);
}
