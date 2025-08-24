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

