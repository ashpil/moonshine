const vk = @import("vulkan");
const std = @import("std");
const VulkanContext = @import("./VulkanContext.zig");

fn typeToObjectType(comptime in: type) vk.ObjectType {
    return switch(in) {
        vk.DescriptorSetLayout => .descriptor_set_layout,
        vk.DescriptorSet => .descriptor_set,
        vk.Buffer => .buffer,
        else => unreachable, // TODO: add more
    };
}

pub fn setDebugName(vc: *const VulkanContext, object: anytype, name: [*:0]const u8) !void {
   if (comptime @import("build_options").vk_validation) {
       try vc.device.setDebugUtilsObjectNameEXT(&.{
           .object_type = comptime typeToObjectType(@TypeOf(object)),
           .object_handle = @enumToInt(object),
           .p_object_name = name,
       });
   }
}

pub fn toPointerType(in: anytype) [*]const @typeInfo(@TypeOf(in)).Pointer.child {
    return @ptrCast([*]const @typeInfo(@TypeOf(in)).Pointer.child, in);
}

pub fn GetInfoSliceReturn(comptime func: anytype) type {
    const params = @typeInfo(@TypeOf(func)).Fn.params;
    const OptionalType = params[params.len - 1].type.?;
    const PtrType = @typeInfo(OptionalType).Optional.child;
    return @typeInfo(PtrType).Pointer.child;
}

// wrapper around functions like vkGetPhysicalDeviceSurfacePresentModesKHR
// they have some initial args, then a length and output address
// this is designed for small stuff to allocate on stack, where size maximum size is comptime known
pub fn getInfoSlice(comptime max_size: comptime_int, func: anytype, partial_args: anytype) !std.BoundedArray(GetInfoSliceReturn(func), max_size) {
    const T = GetInfoSliceReturn(func);

    var buffer: [max_size]T = undefined;
    var len: u32 = max_size;

    const res = try @call(.auto, func, partial_args ++ .{ &len, &buffer });

    if (std.debug.runtime_safety and res == .incomplete) {
        return error.NotEnoughSpace;
    }

    return std.BoundedArray(T, max_size) {
        .buffer = buffer,
        .len = len,
    };
}
