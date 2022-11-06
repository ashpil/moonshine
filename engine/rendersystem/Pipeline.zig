const VulkanContext = @import("./VulkanContext.zig");
const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const utils = @import("./utils.zig");
const Camera = @import("./Camera.zig");

const shaders = @import("shaders");
const vk = @import("vulkan");
const std = @import("std");

const descriptor = @import("./descriptor.zig");
const SceneDescriptorLayout = descriptor.SceneDescriptorLayout;
const BackgroundDescriptorLayout = descriptor.BackgroundDescriptorLayout;
const OutputDescriptorLayout = descriptor.OutputDescriptorLayout;

// defaults for online
const PipelineConstants = struct {
    samples_per_run: u32 = 1,
    max_bounces: u32 = 4,
};

// a "standard" pipeline -- that is, the one we use for most
// rendering operations
pub fn createStandardPipeline(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, cmd: *Commands, scene_descriptor_layout: *const SceneDescriptorLayout, background_descriptor_layout: *const BackgroundDescriptorLayout, output_descriptor_layout: *const OutputDescriptorLayout, constants: PipelineConstants) !Self {
    const rgen_module = try vc.device.createShaderModule(&.{
        .flags = .{},
        .code_size = shaders.raygen.len,
        .p_code = @ptrCast([*]const u32, &shaders.raygen),
    }, null);
    defer vc.device.destroyShaderModule(rgen_module, null);

    const rmiss_module = try vc.device.createShaderModule(&.{
        .flags = .{},
        .code_size = shaders.raymiss.len,
        .p_code = @ptrCast([*]const u32, &shaders.raymiss),
    }, null);
    defer vc.device.destroyShaderModule(rmiss_module, null);

    const rchit_module = try vc.device.createShaderModule(&.{
        .flags = .{},
        .code_size = shaders.rayhit.len,
        .p_code = @ptrCast([*]const u32, &shaders.rayhit),
    }, null);
    defer vc.device.destroyShaderModule(rchit_module, null);

    const shadow_module = try vc.device.createShaderModule(&.{
        .flags = .{},
        .code_size = shaders.shadowmiss.len,
        .p_code = @ptrCast([*]const u32, &shaders.shadowmiss),
    }, null);
    defer vc.device.destroyShaderModule(shadow_module, null);

    const pipeline = try Self.create(vc, vk_allocator, allocator, cmd, &.{ scene_descriptor_layout.handle, background_descriptor_layout.handle, output_descriptor_layout.handle }, &[_]vk.PipelineShaderStageCreateInfo {
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .raygen_bit_khr = true }, .module = rgen_module, .p_name = "main", .p_specialization_info = &vk.SpecializationInfo {
            .map_entry_count = 2,
            .p_map_entries = &[2]vk.SpecializationMapEntry { .{
                .constant_id = 0,
                .offset = 0,
                .size = @sizeOf(u32),
            }, .{
                .constant_id = 1,
                .offset = @sizeOf(u32),
                .size = @sizeOf(u32),
            } },
            .data_size = @sizeOf(PipelineConstants),
            .p_data = &constants,
        }, },
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .miss_bit_khr = true }, .module = rmiss_module, .p_name = "main", .p_specialization_info = null, },
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .miss_bit_khr = true }, .module = shadow_module, .p_name = "main", .p_specialization_info = null, },
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .closest_hit_bit_khr = true }, .module = rchit_module, .p_name = "main", .p_specialization_info = null, },
    }, &[_]vk.RayTracingShaderGroupCreateInfoKHR {
        .{ .@"type" = .general_khr, .general_shader = 0, .closest_hit_shader = vk.SHADER_UNUSED_KHR, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
        .{ .@"type" = .general_khr, .general_shader = 1, .closest_hit_shader = vk.SHADER_UNUSED_KHR, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
        .{ .@"type" = .general_khr, .general_shader = 2, .closest_hit_shader = vk.SHADER_UNUSED_KHR, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
        .{ .@"type" = .triangles_hit_group_khr, .general_shader = vk.SHADER_UNUSED_KHR, .closest_hit_shader = 3, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
    }, &[_]vk.PushConstantRange {
        .{
            .offset = 0,
            .size = @sizeOf(Camera.Desc) + @sizeOf(Camera.BlurDesc) + @sizeOf(u32),
            .stage_flags = .{ .raygen_bit_khr = true },
        }
    });

    return pipeline;
}

const ShaderInfo = struct {
    raygen_count: u32,
    miss_count: u32,
    hit_count: u32,

    fn find(stages: []const vk.PipelineShaderStageCreateInfo) ShaderInfo {

        var raygen_count: u32 = 0;
        var miss_count: u32 = 0;
        var hit_count: u32 = 0;

        for (stages) |stage| {
            if (stage.stage.contains(.{ .raygen_bit_khr = true })) {
                raygen_count += 1;
            } else if (stage.stage.contains(.{ .miss_bit_khr = true })) {
                miss_count += 1;
            } else if (stage.stage.contains(.{ .closest_hit_bit_khr = true })) {
                hit_count += 1;
            }
        }

        return ShaderInfo {
            .raygen_count = raygen_count,
            .miss_count = miss_count,
            .hit_count = hit_count,
        };
    }
};

pub fn traceRays(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, extent: vk.Extent2D) void {
    const callable_table = vk.StridedDeviceAddressRegionKHR {
        .device_address = 0,
        .stride = 0,
        .size = 0,
    };
    vc.device.cmdTraceRaysKHR(command_buffer, &self.sbt.getRaygenSBT(), &self.sbt.getMissSBT(), &self.sbt.getHitSBT(), &callable_table, extent.width, extent.height, 1);
}

layout: vk.PipelineLayout,
handle: vk.Pipeline,
sbt: ShaderBindingTable,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, cmd: *Commands, set_layouts: []const vk.DescriptorSetLayout, stages: []const vk.PipelineShaderStageCreateInfo, groups: []const vk.RayTracingShaderGroupCreateInfoKHR, push_constant_ranges: []const vk.PushConstantRange) !Self {

    var shader_info = ShaderInfo.find(stages);

    const layout = try vc.device.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = @intCast(u32, set_layouts.len),
        .p_set_layouts = set_layouts.ptr,
        .push_constant_range_count = @intCast(u32, push_constant_ranges.len),
        .p_push_constant_ranges = push_constant_ranges.ptr,
    }, null);
    errdefer vc.device.destroyPipelineLayout(layout, null);

    var handle: vk.Pipeline = undefined;
    const createInfo = vk.RayTracingPipelineCreateInfoKHR {
        .flags = .{},
        .stage_count = @intCast(u32, stages.len),
        .p_stages = stages.ptr,
        .group_count = @intCast(u32, groups.len),
        .p_groups = groups.ptr,
        .max_pipeline_ray_recursion_depth = 1,
        .p_library_info = null,
        .p_library_interface = null,
        .p_dynamic_state = null,
        .layout = layout,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };
    _ = try vc.device.createRayTracingPipelinesKHR(.null_handle, .null_handle, 1, @ptrCast([*]const vk.RayTracingPipelineCreateInfoKHR, &createInfo), null, @ptrCast([*]vk.Pipeline, &handle));
    errdefer vc.device.destroyPipeline(handle, null);

    const sbt = try ShaderBindingTable.create(vc, vk_allocator, allocator, handle, cmd, shader_info.raygen_count, shader_info.miss_count, shader_info.hit_count);
    errdefer sbt.destroy(vc);

    return Self {
        .layout = layout,
        .handle = handle,

        .sbt = sbt,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.sbt.destroy(vc);
    vc.device.destroyPipelineLayout(self.layout, null);
    vc.device.destroyPipeline(self.handle, null);
}

const ShaderBindingTable = struct {
    handle: VkAllocator.DeviceBuffer,

    raygen_address: vk.DeviceAddress,
    miss_address: vk.DeviceAddress,
    hit_address: vk.DeviceAddress,

    handle_size_aligned: u32,

    fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, pipeline: vk.Pipeline, cmd: *Commands, raygen_entry_count: u32, miss_entry_count: u32, hit_entry_count: u32) !ShaderBindingTable {
        const handle_size_aligned = std.mem.alignForwardGeneric(u32, vc.physical_device.raytracing_properties.shader_group_handle_size, vc.physical_device.raytracing_properties.shader_group_handle_alignment);
        const group_count = raygen_entry_count + miss_entry_count + hit_entry_count;
        const miss_index = std.mem.alignForwardGeneric(u32, raygen_entry_count * handle_size_aligned, vc.physical_device.raytracing_properties.shader_group_base_alignment);
        const hit_index = std.mem.alignForwardGeneric(u32, miss_index + miss_entry_count * handle_size_aligned, vc.physical_device.raytracing_properties.shader_group_base_alignment);
        const sbt_size = hit_index + hit_entry_count * handle_size_aligned;

        // query sbt from pipeline
        const sbt = try vk_allocator.createHostBuffer(vc, u8, sbt_size, .{ .transfer_src_bit = true });
        defer sbt.destroy(vc);
        try vc.device.getRayTracingShaderGroupHandlesKHR(pipeline, 0, group_count, sbt.data.len, sbt.data.ptr);

        const raygen_size = handle_size_aligned * raygen_entry_count;
        const miss_size = handle_size_aligned * miss_entry_count;
        const hit_size = handle_size_aligned * hit_entry_count;
        
        // must align up to shader_group_base_alignment
        std.mem.copyBackwards(u8, sbt.data[hit_index..hit_index + hit_size], sbt.data[raygen_size + miss_size..raygen_size + miss_size + hit_size]);
        std.mem.copyBackwards(u8, sbt.data[miss_index..miss_index + miss_size], sbt.data[raygen_size..raygen_size + miss_size]);
        
        const handle = try vk_allocator.createDeviceBuffer(vc, allocator, sbt_size, .{ .shader_binding_table_bit_khr = true, .transfer_dst_bit = true, .shader_device_address_bit = true });
        errdefer handle.destroy(vc);

        try cmd.startRecording(vc);
        cmd.recordUploadBuffer(u8, vc, handle, sbt);
        try cmd.submit(vc);

        const raygen_address = handle.getAddress(vc);
        const miss_address = raygen_address + miss_index;
        const hit_address = raygen_address + hit_index;

        try cmd.idleUntilDone(vc);

        return ShaderBindingTable {
            .handle = handle,

            .raygen_address = raygen_address,
            .miss_address = miss_address,
            .hit_address = hit_address,

            .handle_size_aligned = handle_size_aligned,
        };
    }

    pub fn getRaygenSBT(self: *const ShaderBindingTable) vk.StridedDeviceAddressRegionKHR {
        return vk.StridedDeviceAddressRegionKHR {
            .device_address = self.raygen_address,
            .stride = self.handle_size_aligned,
            .size = self.handle_size_aligned, // this will need to change once we have more than one kind of each shader
        }; 
    }

    pub fn getMissSBT(self: *const ShaderBindingTable) vk.StridedDeviceAddressRegionKHR {
        return vk.StridedDeviceAddressRegionKHR {
            .device_address = self.miss_address,
            .stride = self.handle_size_aligned,
            .size = self.handle_size_aligned, // this will need to change once we have more than one kind of each shader
        }; 
    }

    pub fn getHitSBT(self: *const ShaderBindingTable) vk.StridedDeviceAddressRegionKHR {
        return vk.StridedDeviceAddressRegionKHR {
            .device_address = self.hit_address,
            .stride = self.handle_size_aligned,
            .size = self.handle_size_aligned, // this will need to change once we have more than one kind of each shader
        }; 
    }

    fn destroy(self: *ShaderBindingTable, vc: *const VulkanContext) void {
        self.handle.destroy(vc);
    }
};
