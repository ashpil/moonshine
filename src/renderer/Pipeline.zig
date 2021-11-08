const VulkanContext = @import("./VulkanContext.zig");
const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const CameraSize = @import("./Camera.zig").PushInfo;
const utils = @import("./utils.zig");

const vk = @import("vulkan");
const std = @import("std");

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
                errdefer vc.device.destroyShaderModule(module, null);

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
                    .@"type" = comptime if (is_general_shader) .general_khr
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
sbt: ShaderBindingTable,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: *std.mem.Allocator, cmd: *Commands, descriptor_layout: vk.DescriptorSetLayout) !Self {

    var shader_info = try ShaderInfo(.{
        .{ .stage = vk.ShaderStageFlags { .raygen_bit_khr = true }, .filepath = "../../zig-cache/shaders/shader.rgen.spv" },
        .{ .stage = vk.ShaderStageFlags { .miss_bit_khr = true }, .filepath = "../../zig-cache/shaders/shader.rmiss.spv" },
        .{ .stage = vk.ShaderStageFlags { .miss_bit_khr = true }, .filepath = "../../zig-cache/shaders/shadow.rmiss.spv" },
        .{ .stage = vk.ShaderStageFlags { .closest_hit_bit_khr = true }, .filepath = "../../zig-cache/shaders/shader.rchit.spv" },
    }).create(vc);
    defer shader_info.destroy(vc);

    const push_constant_range = vk.PushConstantRange {
        .offset = 0,
        .size = @sizeOf(CameraSize) + @sizeOf(u32),
        .stage_flags = .{ .raygen_bit_khr = true },
    };

    const layout = try vc.device.createPipelineLayout(.{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &descriptor_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast([*]const vk.PushConstantRange, &push_constant_range),
    }, null);
    errdefer vc.device.destroyPipelineLayout(layout, null);

    var handle: vk.Pipeline = undefined;
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
    _ = try vc.device.createRayTracingPipelinesKHR(.null_handle, .null_handle, 1, @ptrCast([*]const vk.RayTracingPipelineCreateInfoKHR, &createInfo), null, @ptrCast([*]vk.Pipeline, &handle));
    errdefer vc.device.destroyPipeline(handle, null);

    const sbt = try ShaderBindingTable.create(vc, vk_allocator, allocator, handle, cmd, 1, 2, 1);
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

fn getRaytracingProperties(vc: *const VulkanContext) vk.PhysicalDeviceRayTracingPipelinePropertiesKHR {
    var raytracing_properties: vk.PhysicalDeviceRayTracingPipelinePropertiesKHR = undefined;
    raytracing_properties.s_type = vk.StructureType.physical_device_ray_tracing_pipeline_properties_khr;
    raytracing_properties.p_next = null;

    vc.instance.getPhysicalDeviceProperties2(vc.physical_device.handle, &.{
        .properties = undefined,
        .p_next = &raytracing_properties,
    });

    return raytracing_properties;
}

const ShaderBindingTable = struct {
    raygen: VkAllocator.DeviceBuffer,
    raygen_address: vk.DeviceAddress,

    miss: VkAllocator.DeviceBuffer,
    miss_address: vk.DeviceAddress,

    hit: VkAllocator.DeviceBuffer,
    hit_address: vk.DeviceAddress,

    handle_size_aligned: u32,

    fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: *std.mem.Allocator, pipeline: vk.Pipeline, cmd: *Commands, comptime raygen_entry_count: comptime_int, comptime miss_entry_count: comptime_int, comptime hit_entry_count: comptime_int) !ShaderBindingTable {
        const rt_properties = getRaytracingProperties(vc);
        const handle_size_aligned = std.mem.alignForwardGeneric(u32, rt_properties.shader_group_handle_size, rt_properties.shader_group_handle_alignment);
        const group_count = raygen_entry_count + miss_entry_count + hit_entry_count;
        const sbt_size = group_count * handle_size_aligned;
        const sbt = try allocator.alloc(u8, sbt_size);
        defer allocator.free(sbt);

        try vc.device.getRayTracingShaderGroupHandlesKHR(pipeline, 0, group_count, sbt.len, sbt.ptr);
        
        const buffer_usage_flags = vk.BufferUsageFlags { .shader_binding_table_bit_khr = true, .transfer_dst_bit = true, .shader_device_address_bit = true };

        const raygen_size = handle_size_aligned * raygen_entry_count;
        const raygen = try vk_allocator.createDeviceBuffer(vc, allocator, raygen_size, buffer_usage_flags);
        errdefer raygen.destroy(vc);
        try cmd.uploadData(vc, vk_allocator, raygen.handle, sbt[0..raygen_size]);
        const raygen_address = raygen.getAddress(vc);

        const miss_size = handle_size_aligned * miss_entry_count;
        const miss = try vk_allocator.createDeviceBuffer(vc, allocator, miss_size, buffer_usage_flags);
        errdefer miss.destroy(vc);
        try cmd.uploadData(vc, vk_allocator, miss.handle, sbt[raygen_size..raygen_size + miss_size]);
        const miss_address = miss.getAddress(vc);

        const hit_size = handle_size_aligned * hit_entry_count;
        const hit = try vk_allocator.createDeviceBuffer(vc, allocator, hit_size, buffer_usage_flags);
        errdefer hit.destroy(vc);
        try cmd.uploadData(vc, vk_allocator, hit.handle, sbt[raygen_size + miss_size..raygen_size + miss_size + hit_size]);
        const hit_address = hit.getAddress(vc);

        return ShaderBindingTable {
            .raygen = raygen,
            .raygen_address = raygen_address,

            .miss = miss,
            .miss_address = miss_address,

            .hit = hit,
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
        self.raygen.destroy(vc);
        self.miss.destroy(vc);
        self.hit.destroy(vc);
    }
};
