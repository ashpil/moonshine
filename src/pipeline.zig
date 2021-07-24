const VulkanContext = @import("./vulkan_context.zig");
const DescriptorSet = @import("./descriptor_set.zig");
const vk = @import("vulkan");
const std = @import("std");

fn createStage(vc: *const VulkanContext, stage: vk.ShaderStageFlags, comptime filepath: []const u8) !vk.PipelineShaderStageCreateInfo {
    const code = @embedFile(filepath);

    const module = try vc.device.createShaderModule(.{
        .flags = .{},
        .code_size = code.len,
        .p_code = @ptrCast([*]const u32, code),
    }, null);

    return vk.PipelineShaderStageCreateInfo {
        .flags = .{},
        .stage = stage,
        .module = module,
        .p_name = "main",
        .p_specialization_info = null,
    };
}

layout: vk.PipelineLayout,
handle: vk.Pipeline,

const Self = @This();

pub fn create(vc: *const VulkanContext, descriptor_set: *const DescriptorSet) !Self {

    const stages = [_]vk.PipelineShaderStageCreateInfo {
        try createStage(vc, .{ .raygen_bit_khr = true}, "../zig-cache/shaders/rgen.spv"),
    };

    defer for (stages) |stage| {
        vc.device.destroyShaderModule(stage.module, null);
    };

    const layout = try vc.device.createPipelineLayout(.{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &descriptor_set.layout),
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);

    var pipeline: vk.Pipeline = undefined;
    const createInfo = vk.RayTracingPipelineCreateInfoKHR {
        .flags = .{},
        .stage_count = stages.len,
        .p_stages = &stages,
        .group_count = 0,
        .p_groups = undefined,
        .max_pipeline_ray_recursion_depth = 0,
        .p_library_info = null,
        .p_library_interface = null,
        .p_dynamic_state = null,
        .layout = layout,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };
    _ = try vc.device.createRayTracingPipelinesKHR(.null_handle, .null_handle, 1, @ptrCast([*]const vk.RayTracingPipelineCreateInfoKHR, &createInfo), null, @ptrCast([*]vk.Pipeline, &pipeline));

    return Self {
        .layout = layout,
        .handle = pipeline,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    vc.device.destroyPipelineLayout(self.layout, null);
    vc.device.destroyPipeline(self.handle, null);
}
