const VulkanContext = @import("./vulkan_context.zig").VulkanContext;
const vk = @import("vulkan");

pub const RaytracingPipeline = struct {

    handle: vk.Pipeline,

    pub fn create(vc: *VulkanContext) !RaytracingPipeline {
        var pipeline: vk.Pipeline = undefined;
        const createInfo = vk.RayTracingPipelineCreateInfoKHR {
            .flags = .{},
            .stage_count = 0,
            .p_stages = undefined,
            .group_count = 0,
            .p_groups = undefined,
            .max_pipeline_ray_recursion_depth = 0,
            .p_library_info = null,
            .p_library_interface = null,
            .p_dynamic_state = null,
            .layout = undefined,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };
        _ = try vc.device.createRayTracingPipelinesKHR(.null_handle, .null_handle, 1, @ptrCast([*]const vk.RayTracingPipelineCreateInfoKHR, &createInfo), null, @ptrCast([*]vk.Pipeline, &pipeline));

        return RaytracingPipeline {
            .handle = pipeline,
        };
    }

    pub fn destroy(self: *RaytracingPipeline, vc: *VulkanContext) void {
        vc.device.destroyPipeline(self.handle, null);
    }
};