const VulkanContext = @import("./VulkanContext.zig");
const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const utils = @import("./utils.zig");
const Camera = @import("./Camera.zig");

const shaders = @import("shaders");
const vk = @import("vulkan");
const std = @import("std");

const F32x2 = @import("../vector.zig").Vec2(f32);

const descriptor = @import("./descriptor.zig");
const WorldDescriptorLayout = descriptor.WorldDescriptorLayout;
const BackgroundDescriptorLayout = descriptor.BackgroundDescriptorLayout;
const FilmDescriptorLayout = descriptor.FilmDescriptorLayout;
const InputDescriptorLayout = descriptor.InputDescriptorLayout;

const PushConstant = struct {
    type: type,
    stage_flags: vk.ShaderStageFlags,
};

pub fn Pipeline(
        comptime shader_code: anytype,
        comptime SetLayouts: type,
        comptime SpecConstants: type,
        comptime push_constant_ranges: []const vk.PushConstantRange,
        comptime stages: []const vk.PipelineShaderStageCreateInfo,
        comptime groups: []const vk.RayTracingShaderGroupCreateInfoKHR,
    ) type {

    return struct {
        layout: vk.PipelineLayout,
        handle: vk.Pipeline,
        sbt: ShaderBindingTable,

        const Self = @This();

        pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, cmd: *Commands, set_layouts: SetLayouts, constants: SpecConstants) !Self {
            var set_layout_handles: [set_layouts.len]vk.DescriptorSetLayout = undefined;
            inline for (set_layout_handles) |*handle, i| {
                handle.* = set_layouts[i].handle;
            }
            const layout = try vc.device.createPipelineLayout(&.{
                .flags = .{},
                .set_layout_count = set_layout_handles.len,
                .p_set_layouts = &set_layout_handles,
                .push_constant_range_count = push_constant_ranges.len,
                .p_push_constant_ranges = push_constant_ranges.ptr,
            }, null);
            errdefer vc.device.destroyPipelineLayout(layout, null);

            const module = try vc.device.createShaderModule(&.{
                .flags = .{},
                .code_size = shader_code.len,
                .p_code = @ptrCast([*]const u32, @alignCast(@alignOf(u32), &shader_code)),
            }, null);
            defer vc.device.destroyShaderModule(module, null);

            var var_stages: [stages.len]vk.PipelineShaderStageCreateInfo = undefined;
            inline for (var_stages) |*stage, i| {
                stage.* = stages[i];
                stage.module = module;
            }

            inline for (@typeInfo(SpecConstants).Struct.fields) |field, i| {
                if (@sizeOf(field.type) != 0) {
                    const inner_fields = @typeInfo(field.type).Struct.fields;
                    var map_entries: [inner_fields.len]vk.SpecializationMapEntry = undefined;
                    inline for (map_entries) |*map_entry, j| {
                        map_entry.* = vk.SpecializationMapEntry {
                            .constant_id = j,
                            .offset = @bitOffsetOf(field.type, inner_fields[j].name) / 8,
                            .size = @sizeOf(inner_fields[j].type),
                        };
                    }
                    var_stages[i].p_specialization_info = &vk.SpecializationInfo {
                        .map_entry_count = map_entries.len,
                        .p_map_entries = &map_entries,
                        .data_size = @sizeOf(field.type),
                        .p_data = &@field(constants, field.name),
                    };
                }
            }

            var handle: vk.Pipeline = undefined;
            const createInfo = vk.RayTracingPipelineCreateInfoKHR {
                .flags = .{},
                .stage_count = var_stages.len,
                .p_stages = &var_stages,
                .group_count = groups.len,
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

            const shader_info = ShaderInfo.find(stages);
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

        pub fn recordTraceRays(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, extent: vk.Extent2D) void {
            const callable_table = vk.StridedDeviceAddressRegionKHR {
                .device_address = 0,
                .stride = 0,
                .size = 0,
            };
            vc.device.cmdTraceRaysKHR(command_buffer, &self.sbt.getRaygenSBT(), &self.sbt.getMissSBT(), &self.sbt.getHitSBT(), &callable_table, extent.width, extent.height, 1);
        }
    };
}

pub const ObjectPickPipeline = Pipeline(
    shaders.input,
    struct {
        InputDescriptorLayout,
        WorldDescriptorLayout,
    },
    struct {},
    &[_]vk.PushConstantRange {
        .{
            .offset = 0,
            .size = @sizeOf(Camera.Desc) + @sizeOf(F32x2),
            .stage_flags = .{ .raygen_bit_khr = true },
        },
    },
    &[_]vk.PipelineShaderStageCreateInfo {
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .raygen_bit_khr = true }, .module = undefined, .p_name = "raygen", .p_specialization_info = null, },
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .miss_bit_khr = true }, .module = undefined, .p_name = "miss", .p_specialization_info = null, },
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .closest_hit_bit_khr = true }, .module = undefined, .p_name = "chit", .p_specialization_info = null, },
    },
    &[_]vk.RayTracingShaderGroupCreateInfoKHR {
        .{ .@"type" = .general_khr, .general_shader = 0, .closest_hit_shader = vk.SHADER_UNUSED_KHR, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
        .{ .@"type" = .general_khr, .general_shader = 1, .closest_hit_shader = vk.SHADER_UNUSED_KHR, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
        .{ .@"type" = .triangles_hit_group_khr, .general_shader = vk.SHADER_UNUSED_KHR, .closest_hit_shader = 2, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
    },
);

// a "standard" pipeline -- that is, the one we use for most
// rendering operations
pub const StandardPipeline = Pipeline(
    shaders.main,
    struct {
        WorldDescriptorLayout,
        BackgroundDescriptorLayout,
        FilmDescriptorLayout,
    },
    struct {
        @"0": extern struct {
            samples_per_run: u32 = 1,
            max_bounces: u32 = 4,
            env_samples_per_bounce: u32 = 1,
            mesh_samples_per_bounce: u32 = 1,
        } = .{},
    },
    &[_]vk.PushConstantRange {
        .{
            .offset = 0,
            .size = @sizeOf(Camera.Desc) + @sizeOf(Camera.BlurDesc) + @sizeOf(u32),
            .stage_flags = .{ .raygen_bit_khr = true },
        }
    },
    &[_]vk.PipelineShaderStageCreateInfo {
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .raygen_bit_khr = true }, .module = undefined, .p_name = "raygen", .p_specialization_info = null },
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .miss_bit_khr = true }, .module = undefined, .p_name = "miss", .p_specialization_info = null, },
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .miss_bit_khr = true }, .module = undefined, .p_name = "shadowmiss", .p_specialization_info = null, },
        .{ .flags = .{}, .stage = vk.ShaderStageFlags { .closest_hit_bit_khr = true }, .module = undefined, .p_name = "closesthit", .p_specialization_info = null, },
    },
    &[_]vk.RayTracingShaderGroupCreateInfoKHR {
        .{ .@"type" = .general_khr, .general_shader = 0, .closest_hit_shader = vk.SHADER_UNUSED_KHR, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
        .{ .@"type" = .general_khr, .general_shader = 1, .closest_hit_shader = vk.SHADER_UNUSED_KHR, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
        .{ .@"type" = .general_khr, .general_shader = 2, .closest_hit_shader = vk.SHADER_UNUSED_KHR, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
        .{ .@"type" = .triangles_hit_group_khr, .general_shader = vk.SHADER_UNUSED_KHR, .closest_hit_shader = 3, .any_hit_shader = vk.SHADER_UNUSED_KHR, .intersection_shader = vk.SHADER_UNUSED_KHR, .p_shader_group_capture_replay_handle = null },
    },
);

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
