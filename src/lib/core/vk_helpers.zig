const vk = @import("vulkan");
const std = @import("std");
const VulkanContext = @import("./VulkanContext.zig");
const build_options = @import("build_options");

pub fn typeToObjectType(comptime in: type) vk.ObjectType {
    return switch(in) {
        vk.DescriptorSetLayout => .descriptor_set_layout,
        vk.DescriptorSet => .descriptor_set,
        vk.Buffer => .buffer,
        vk.CommandBuffer => .command_buffer,
        vk.Image => .image,
        vk.Pipeline => .pipeline,
        vk.PipelineLayout => .pipeline_layout,
        vk.ShaderModule => .shader_module,
        vk.DeviceMemory => .device_memory,
        vk.SwapchainKHR => .swapchain_khr,
        vk.ImageView => .image_view,
        vk.AccelerationStructureKHR => .acceleration_structure_khr,
        else => @compileError("unknown type " ++ @typeName(in)), // TODO: add more
    };
}

pub fn setDebugName(device: VulkanContext.Device, object: anytype, name: [*:0]const u8) !void {
    // TODO: this does not make sense, debug names can be needed separately from validation
    // for other types of debugging/profiling
    const want_debug_names = build_options.vk_validation != .ignore;

    if ((comptime want_debug_names) and object != .null_handle) {
        try device.setDebugUtilsObjectNameEXT(&.{
            .object_type = comptime typeToObjectType(@TypeOf(object)),
            .object_handle = @intFromEnum(object),
            .p_object_name = name,
        });
    }
}

pub fn texelBlockSize(format: vk.Format) vk.DeviceSize {
    return switch (format) {
        .r8_unorm => 1,
        .r8g8_unorm => 2,
        .r8g8b8a8_srgb, .r32_sfloat => 4,
        .r32g32_sfloat => 8,
        .r32g32b32a32_sfloat => 16,
        else => unreachable, // TODO
    };
}

pub fn typeToFormat(comptime in: type) vk.Format {
    const vector = @import("../engine.zig").vector;
    return switch (in) {
        u8 => .r8_unorm,
        vector.Vec2(u8) => .r8g8_unorm,
        vector.Vec4(u8) => .r8g8b8a8_srgb, // TODO: not assume srgb
        f32 => .r32_sfloat,
        vector.Vec2(f32) => .r32g32_sfloat,
        vector.Vec4(f32) => .r32g32b32a32_sfloat,
        else => unreachable, // TODO
    };
}


fn GetVkSliceInternal(comptime func: anytype) type {
    const params = @typeInfo(@TypeOf(func)).@"fn".params;
    const OptionalType = params[params.len - 1].type.?;
    const PtrType = @typeInfo(OptionalType).optional.child;
    return @typeInfo(PtrType).pointer.child;
}

fn GetVkSliceBoundedReturn(comptime max_size: comptime_int, comptime func: anytype) type {
    const FuncReturn = @typeInfo(@TypeOf(func)).@"fn".return_type.?;

    const BaseReturn = std.BoundedArray(GetVkSliceInternal(func), max_size);

    return switch (@typeInfo(FuncReturn)) {
        .error_union => |err| err.error_set!BaseReturn,
        .void => BaseReturn,
        else => unreachable,
    };
}

// wrapper around functions like vkGetPhysicalDeviceSurfacePresentModesKHR
// they have some initial args, then a length and output address
// this is designed for small stuff to allocate on stack, where size maximum size is comptime known
//
// in optimized modes, only calls the actual function only once, based on the assumption that the caller correctly predicts max possible return size.
// in safe modes, checks that the actual size does not exceed the maximum size, which may call the function more than once
pub fn getVkSliceBounded(comptime max_size: comptime_int, func: anytype, partial_args: anytype) GetVkSliceBoundedReturn(max_size, func) {
    const T = GetVkSliceInternal(func);

    var buffer: [max_size]T = undefined;
    var len: u32 = max_size;

    const always_succeeds = @typeInfo(@TypeOf(func)).@"fn".return_type == void;
    if (always_succeeds) {
        if (std.debug.runtime_safety) {
            var actual_len: u32 = undefined;
            @call(.auto, func, partial_args ++ .{ &actual_len, null });
            std.debug.assert(actual_len < max_size);
        }
        @call(.auto, func, partial_args ++ .{ &len, &buffer });
    } else {
        const res = try @call(.auto, func, partial_args ++ .{ &len, &buffer });
        std.debug.assert(res != .incomplete);
    }

    return std.BoundedArray(T, max_size) {
        .buffer = buffer,
        .len = @intCast(len),
    };
}

pub fn getVkSlice(allocator: std.mem.Allocator, func: anytype, partial_args: anytype) ![]GetVkSliceInternal(func) {
    const T = GetVkSliceInternal(func);

    var len: u32 = undefined;
    _ = try @call(.auto, func, partial_args ++ .{ &len, null });

    const buffer = try allocator.alloc(T, len);

    const res = try @call(.auto, func, partial_args ++ .{ &len, buffer.ptr });
    std.debug.assert(res != .incomplete);

    return buffer;
}
