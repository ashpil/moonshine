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

fn ShaderInfo(comptime infos: anytype) type {
    return struct {
        const ShaderStruct = @This();

        stages: [infos.len]vk.PipelineShaderStageCreateInfo,
        groups: [infos.len]vk.RayTracingShaderGroupCreateInfoKHR,

        fn create(vc: *const VulkanContext) !ShaderStruct {

            var stages: [infos.len]vk.PipelineShaderStageCreateInfo = undefined;
            var groups: [infos.len]vk.RayTracingShaderGroupCreateInfoKHR = undefined;

            inline for (infos) |info, i| {
                const code = @embedFile(info.filepath);

                const module = try vc.device.createShaderModule(.{
                    .flags = .{},
                    .code_size = code.len,
                    .p_code = @ptrCast([*]const u32, code),
                }, null);

                stages[i] = vk.PipelineShaderStageCreateInfo {
                    .flags = .{},
                    .stage = info.stage,
                    .module = module,
                    .p_name = "main",
                    .p_specialization_info = null,
                };
                
                // sort underthought for now; needs to be improved for when there are more groups
                const is_general_shader = comptime info.stage.contains(.{ .raygen_bit_khr = true }) or info.stage.contains(.{ .miss_bit_khr = true });
                const is_closest_hit_shader = comptime info.stage.contains(.{ .closest_hit_bit_khr = true });
                groups[i] = vk.RayTracingShaderGroupCreateInfoKHR {
                    .type_ = comptime if (is_general_shader) .general_khr
                        else if (is_closest_hit_shader) .triangles_hit_group_khr
                        else @compileError("Unknown shader stage!"),
                    .general_shader = comptime if (is_general_shader) i
                        else if (is_closest_hit_shader) vk.SHADER_UNUSED_KHR
                        else @compileError("Unknown shader stage!"),
                    .closest_hit_shader = comptime if (is_general_shader) vk.SHADER_UNUSED_KHR
                        else if (is_closest_hit_shader) i
                        else @compileError("Unknown shader stage!"),
                    .any_hit_shader = vk.SHADER_UNUSED_KHR,
                    .intersection_shader = vk.SHADER_UNUSED_KHR,
                    .p_shader_group_capture_replay_handle = null,
                };
            }

            return ShaderStruct {
                .stages = stages,
                .groups = groups,
            };
        }

        fn destroy(self: *ShaderStruct, vc: *const VulkanContext) void {
            for (self.stages) |stage| {
                vc.device.destroyShaderModule(stage.module, null);
            }
        }
    };
}

layout: vk.PipelineLayout,
handle: vk.Pipeline,

const Self = @This();

pub fn create(vc: *const VulkanContext, descriptor_set: *const DescriptorSet) !Self {

    var shader_info = try ShaderInfo(.{
        .{ .stage = vk.ShaderStageFlags { .raygen_bit_khr = true }, .filepath = "../zig-cache/shaders/rgen.spv" },
    }).create(vc);
    defer shader_info.destroy(vc);

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
        .stage_count = shader_info.stages.len,
        .p_stages = &shader_info.stages,
        .group_count = shader_info.groups.len,
        .p_groups = &shader_info.groups,
        .max_pipeline_ray_recursion_depth = 1,
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
