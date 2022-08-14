const vk = @import("vulkan");
const std = @import("std");
const VulkanContext = @import("./VulkanContext.zig");

fn typeToObjectType(comptime in: type) vk.ObjectType {
    return switch(in) {
        vk.DescriptorSetLayout => .descriptor_set_layout,
        else => unreachable, // TODO: add more
    };
}

// TODO: use this
//pub fn setDebugName(vc: *const VulkanContext, object: anytype, name: [*:0]const u8) !void {
//    if (comptime @import("builtin").mode == std.builtin.Mode.Debug) {
//        try vc.device.setDebugUtilsObjectNameEXT(&.{
//            .object_type = comptime typeToObjectType(@TypeOf(object)),
//            .object_handle = @bitCast(u64, object),
//            .p_object_name = name,
//        });
//    }
//}

pub fn toPointerType(in: anytype) [*]const @typeInfo(@TypeOf(in)).Pointer.child {
    return @ptrCast([*]const @typeInfo(@TypeOf(in)).Pointer.child, in);
}
