const shaders = @import("shaders");
const vk = @import("vulkan");
const std = @import("std");
const build_options = @import("build_options");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const descriptor = core.descriptor;

const Camera = @import("./Camera.zig");

const vector = engine.vector;
const F32x2 = vector.Vec2(f32);
const F32x3 = vector.Vec3(f32);

const StageType = enum {
    miss,
    raygen,
    callable,
    closest_hit,

    fn to_vk_stage(self: StageType) vk.ShaderStageFlags {
        return switch (self) {
            .miss => .{ .miss_bit_khr = true },
            .raygen => .{ .raygen_bit_khr = true },
            .callable => .{ .callable_bit_khr = true },
            .closest_hit => .{ .closest_hit_bit_khr = true },
        };
    }

    fn to_vk_group(self: StageType) vk.RayTracingShaderGroupTypeKHR {
        return switch (self) {
            .miss => .general_khr,
            .raygen => .general_khr,
            .callable => .general_khr,
            .closest_hit => .triangles_hit_group_khr,
        };
    }

    fn name(self: StageType) []const u8 {
        return switch (self) {
            .miss => "general_shader",
            .raygen => "general_shader",
            .callable => "general_shader",
            .closest_hit => "closest_hit_shader",
        };
    }
};

const Stage = struct {
    entrypoint: [*:0]const u8,
    type: StageType,
};

pub fn Pipeline(comptime options: struct {
    shader_path: [:0]const u8,
    SpecConstants: type = struct {},
    PushConstants: type = struct {},
    PushSetBindings: type,
    additional_descriptor_layout_count: comptime_int = 0,
    stages: []const Stage,
}) type {

    return struct {
        bindings: Bindings,
        handle: vk.Pipeline,
        sbt: ShaderBindingTable,

        const Self = @This();

        const Bindings = core.pipeline.PipelineBindings(options.shader_path, .{ .raygen_bit_khr = true }, options.PushConstants, options.PushSetBindings, options.additional_descriptor_layout_count);

        pub const SpecConstants = options.SpecConstants;
        pub const PushSetBindings = options.PushSetBindings;

        pub fn create(vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, additional_descriptor_layouts: [options.additional_descriptor_layout_count]vk.DescriptorSetLayout, constants: SpecConstants, samplers: [Bindings.sampler_count]vk.Sampler) !Self {
            var bindings = try Bindings.create(vc, samplers, additional_descriptor_layouts);
            errdefer bindings.destroy(vc);

            const module = try core.pipeline.createShaderModule(vc, options.shader_path, allocator, .ray_tracing);
            defer vc.device.destroyShaderModule(module, null);

            var vk_stages: [options.stages.len]vk.PipelineShaderStageCreateInfo = undefined;
            var vk_groups: [options.stages.len]vk.RayTracingShaderGroupCreateInfoKHR = undefined;
            inline for (options.stages, &vk_stages, &vk_groups, 0..) |stage, *vk_stage, *vk_group, i| {
                vk_stage.* = vk.PipelineShaderStageCreateInfo {
                    .module = module,
                    .p_name = stage.entrypoint,
                    .stage = stage.type.to_vk_stage(),
                };
                vk_group.* = vk.RayTracingShaderGroupCreateInfoKHR {
                    .type = stage.type.to_vk_group(),
                    .general_shader = vk.SHADER_UNUSED_KHR,
                    .closest_hit_shader = vk.SHADER_UNUSED_KHR,
                    .any_hit_shader = vk.SHADER_UNUSED_KHR,
                    .intersection_shader = vk.SHADER_UNUSED_KHR,
                };
                @field(vk_group, stage.type.name()) = i;
            }

            if (@sizeOf(SpecConstants) != 0) {
                const inner_fields = @typeInfo(SpecConstants).@"struct".fields;
                var map_entries: [inner_fields.len]vk.SpecializationMapEntry = undefined;
                inline for (&map_entries, inner_fields, 0..) |*map_entry, inner_field, j| {
                    map_entry.* = vk.SpecializationMapEntry {
                        .constant_id = j,
                        .offset = @offsetOf(SpecConstants, inner_field.name),
                        .size = inner_field.alignment,
                    };
                }

                for (options.stages, &vk_stages) |stage, *vk_stage|{
                    // only use specialization constants in raygen
                    if (stage.type == .raygen) {
                        vk_stage.p_specialization_info = &vk.SpecializationInfo {
                            .map_entry_count = map_entries.len,
                            .p_map_entries = &map_entries,
                            .data_size = @sizeOf(SpecConstants),
                            .p_data = &constants,
                        };
                    }
                }
            }

            const create_info = vk.RayTracingPipelineCreateInfoKHR {
                .stage_count = vk_stages.len,
                .p_stages = &vk_stages,
                .group_count = vk_groups.len,
                .p_groups = &vk_groups,
                .max_pipeline_ray_recursion_depth = 1,
                .layout = bindings.layout,
                .base_pipeline_handle = .null_handle,
                .base_pipeline_index = -1,
            };
            var handle: vk.Pipeline = undefined;
            _ = try vc.device.createRayTracingPipelinesKHR(.null_handle, .null_handle, 1, @ptrCast(&create_info), null, @ptrCast(&handle));
            errdefer vc.device.destroyPipeline(handle, null);
            try core.vk_helpers.setDebugName(vc.device, handle, options.shader_path);

            const shader_info = comptime ShaderInfo.find(options.stages);
            const sbt = try ShaderBindingTable.create(vc, handle, encoder, shader_info.raygen_count, shader_info.miss_count, shader_info.hit_count, shader_info.callable_count);
            errdefer sbt.destroy(vc);

            return Self {
                .bindings = bindings,
                .handle = handle,

                .sbt = sbt,
            };
        }

        // returns old handle which must be cleaned up
        pub fn recreate(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, constants: SpecConstants) !vk.Pipeline {
            const module = try core.pipeline.createShaderModule(vc, options.shader_path, allocator, .ray_tracing);
            defer vc.device.destroyShaderModule(module, null);

            var vk_stages: [options.stages.len]vk.PipelineShaderStageCreateInfo = undefined;
            var vk_groups: [options.stages.len]vk.RayTracingShaderGroupCreateInfoKHR = undefined;
            inline for (options.stages, &vk_stages, &vk_groups, 0..) |stage, *vk_stage, *vk_group, i| {
                vk_stage.* = vk.PipelineShaderStageCreateInfo {
                    .module = module,
                    .p_name = stage.entrypoint,
                    .stage = stage.type.to_vk_stage(),
                };
                vk_group.* = vk.RayTracingShaderGroupCreateInfoKHR {
                    .type = stage.type.to_vk_group(),
                    .general_shader = vk.SHADER_UNUSED_KHR,
                    .closest_hit_shader = vk.SHADER_UNUSED_KHR,
                    .any_hit_shader = vk.SHADER_UNUSED_KHR,
                    .intersection_shader = vk.SHADER_UNUSED_KHR,
                };
                @field(vk_group, stage.type.name()) = i;
            }

            if (@sizeOf(SpecConstants) != 0) {
                const inner_fields = @typeInfo(SpecConstants).@"struct".fields;
                var map_entries: [inner_fields.len]vk.SpecializationMapEntry = undefined;
                inline for (&map_entries, inner_fields, 0..) |*map_entry, inner_field, j| {
                    map_entry.* = vk.SpecializationMapEntry {
                        .constant_id = j,
                        .offset = @offsetOf(SpecConstants, inner_field.name),
                        .size = inner_field.alignment, // not completely sure this is right -- purpose is so that e.g., we can have a 32 bit bool. should work.
                    };
                }

                for (options.stages, &vk_stages) |stage, *vk_stage|{
                    // only use specialization constants in raygen
                    if (stage.type == .raygen) {
                        vk_stage.p_specialization_info = &vk.SpecializationInfo {
                            .map_entry_count = map_entries.len,
                            .p_map_entries = &map_entries,
                            .data_size = @sizeOf(SpecConstants),
                            .p_data = &constants,
                        };
                    }
                }
            }

            const create_info = vk.RayTracingPipelineCreateInfoKHR {
                .stage_count = vk_stages.len,
                .p_stages = &vk_stages,
                .group_count = vk_groups.len,
                .p_groups = &vk_groups,
                .max_pipeline_ray_recursion_depth = 1,
                .layout = self.bindings.layout,
                .base_pipeline_handle = .null_handle,
                .base_pipeline_index = -1,
            };
            const old_handle = self.handle;
            _ = try vc.device.createRayTracingPipelinesKHR(.null_handle, .null_handle, 1, @ptrCast(&create_info), null, @ptrCast(&self.handle));
            errdefer vc.device.destroyPipeline(self.handle, null);
            try core.vk_helpers.setDebugName(vc.device, self.handle, options.shader_path);

            try self.sbt.recreate(vc, self.handle, encoder);

            return old_handle;
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            self.sbt.destroy(vc);
            vc.device.destroyPipeline(self.handle, null);
            self.bindings.destroy(vc);
        }

        pub fn recordBindPipeline(self: *const Self, command_buffer: VulkanContext.CommandBuffer) void {
            command_buffer.bindPipeline(.ray_tracing_khr, self.handle);
        }

        pub usingnamespace if (options.additional_descriptor_layout_count != 0) struct {
            pub fn recordBindAdditionalDescriptorSets(self: *const Self, command_buffer: VulkanContext.CommandBuffer, sets: [options.additional_descriptor_layout_count]vk.DescriptorSet) void {
                command_buffer.bindDescriptorSets(.ray_tracing_khr, self.bindings.layout, 1, sets.len, &sets, 0, undefined);
            }
        } else struct {};

        pub usingnamespace if (@sizeOf(options.PushConstants) != 0) struct {
            pub fn recordPushConstants(self: *const Self, command_buffer: VulkanContext.CommandBuffer, constants: options.PushConstants) void {
                const bytes = std.mem.asBytes(&constants);
                command_buffer.pushConstants(self.bindings.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);
            }
        } else struct {};

        pub fn recordTraceRays(self: *const Self, command_buffer: VulkanContext.CommandBuffer, extent: vk.Extent2D) void {
            command_buffer.traceRaysKHR(&self.sbt.getRaygenSBT(), &self.sbt.getMissSBT(), &self.sbt.getHitSBT(), &self.sbt.getCallableSBT(), extent.width, extent.height, 1);
        }

        pub fn recordPushDescriptors(self: *const Self, command_buffer: VulkanContext.CommandBuffer, bindings: options.PushSetBindings) void {
            const writes = core.pipeline.pushDescriptorDataToWriteDescriptor(options.PushSetBindings, bindings);
            command_buffer.pushDescriptorSetKHR(.ray_tracing_khr, self.bindings.layout, 0, @intCast(writes.len), &writes.buffer);
        }
    };
}

pub const ObjectPickPipeline = Pipeline(.{
    .shader_path = "hrtsystem/input.hlsl",
    .PushConstants = extern struct {
        lens: Camera.Lens,
        aspect_ratio: f32,
        click_position: F32x2,
    },
    .PushSetBindings = struct {
        tlas: vk.AccelerationStructureKHR,
        output_image: core.pipeline.StorageImage,
        click_data: vk.Buffer,
    },
    .stages = &[_]Stage {
        .{ .type = .raygen, .entrypoint = "raygen" },
        .{ .type = .miss, .entrypoint = "miss" },
        .{ .type = .closest_hit, .entrypoint = "closesthit" },
    }
});

pub const StandardBindings = struct {
    tlas: ?vk.AccelerationStructureKHR,
    instances: ?vk.Buffer,
    world_to_instances: ?vk.Buffer,
    meshes: ?vk.Buffer,
    geometries: ?vk.Buffer,
    material_values: ?vk.Buffer,
    triangle_power_image: core.pipeline.SampledImage,
    triangle_meta: vk.Buffer,
    geometry_to_triangle_power_offset: vk.Buffer,
    emissive_triangle_count: vk.Buffer,
    background_rgb_image: core.pipeline.CombinedImageSampler,
    background_luminance_image: core.pipeline.SampledImage,
    output_image: core.pipeline.StorageImage,
};

pub const PathTracing = Pipeline(.{
    .shader_path = "hrtsystem/main_pt.hlsl",
    .SpecConstants = extern struct {
        max_bounces: u32 = 4,
        env_samples_per_bounce: u32 = 1,
        mesh_samples_per_bounce: u32 = 1,
    },
    .PushConstants = extern struct {
        lens: Camera.Lens,
        aspect_ratio: f32,
        sample_count: u32,
    },
    .additional_descriptor_layout_count = 2,
    .PushSetBindings = StandardBindings,
    .stages = &[_]Stage {
        .{ .type = .raygen, .entrypoint = "raygen" },
        .{ .type = .miss, .entrypoint = "miss" },
        .{ .type = .miss, .entrypoint = "shadowmiss" },
        .{ .type = .closest_hit, .entrypoint = "closesthit" },
    }
});

pub const DirectLighting = Pipeline(.{
    .shader_path = "hrtsystem/main_direct.hlsl",
    .SpecConstants = extern struct {
        env_samples: u32 = 1,
        mesh_samples: u32 = 1,
        brdf_samples: u32 = 1,
    },
    .PushConstants = extern struct {
        lens: Camera.Lens,
        aspect_ratio: f32,
        sample_count: u32,
    },
    .additional_descriptor_layout_count = 2,
    .PushSetBindings = StandardBindings,
    .stages = &[_]Stage {
        .{ .type = .raygen, .entrypoint = "raygen" },
        .{ .type = .miss, .entrypoint = "miss" },
        .{ .type = .miss, .entrypoint = "shadowmiss" },
        .{ .type = .closest_hit, .entrypoint = "closesthit" },
    }
});

const ShaderInfo = struct {
    raygen_count: u32,
    miss_count: u32,
    hit_count: u32,
    callable_count: u32,

    fn find(stages: []const Stage) ShaderInfo {

        var raygen_count: u32 = 0;
        var miss_count: u32 = 0;
        var hit_count: u32 = 0;
        var callable_count: u32 = 0;

        for (stages) |stage| {
            switch (stage.type) {
                .miss => miss_count += 1,
                .raygen => raygen_count += 1,
                .callable => callable_count += 1,
                .closest_hit => hit_count += 1,
            }
        }

        return ShaderInfo {
            .raygen_count = raygen_count,
            .miss_count = miss_count,
            .hit_count = hit_count,
            .callable_count = callable_count,
        };
    }
};

const ShaderBindingTable = struct {
    handle: core.mem.DeviceBuffer(u8, .{ .shader_binding_table_bit_khr = true, .transfer_dst_bit = true, .shader_device_address_bit = true }),

    raygen_address: vk.DeviceAddress,
    miss_address: vk.DeviceAddress,
    hit_address: vk.DeviceAddress,
    callable_address: vk.DeviceAddress,

    raygen_count: u32,
    miss_count: u32,
    hit_count: u32,
    callable_count: u32,

    handle_size_aligned: u32,

    fn create(vc: *const VulkanContext, pipeline: vk.Pipeline, encoder: *Encoder, raygen_entry_count: u32, miss_entry_count: u32, hit_entry_count: u32, callable_entry_count: u32) !ShaderBindingTable {
        const rt_properties = blk: {
            var rt_properties: vk.PhysicalDeviceRayTracingPipelinePropertiesKHR = undefined;
            rt_properties.s_type = .physical_device_ray_tracing_pipeline_properties_khr;
            rt_properties.p_next = null;

            var properties2 = vk.PhysicalDeviceProperties2 {
                .properties = undefined,
                .p_next = &rt_properties,
            };

            vc.instance.getPhysicalDeviceProperties2(vc.physical_device.handle, &properties2);

            break :blk rt_properties;
        };

        const handle_size_aligned = std.mem.alignForward(u32, rt_properties.shader_group_handle_size, rt_properties.shader_group_handle_alignment);
        const group_count = raygen_entry_count + miss_entry_count + hit_entry_count + callable_entry_count;

        const raygen_index = 0;
        const miss_index = std.mem.alignForward(u32, raygen_index + raygen_entry_count * handle_size_aligned, rt_properties.shader_group_base_alignment);
        const hit_index = std.mem.alignForward(u32, miss_index + miss_entry_count * handle_size_aligned, rt_properties.shader_group_base_alignment);
        const callable_index = std.mem.alignForward(u32, hit_index + hit_entry_count * handle_size_aligned, rt_properties.shader_group_base_alignment);
        const sbt_size = callable_index + callable_entry_count * handle_size_aligned;

        // query sbt from pipeline
        const sbt = try encoder.uploadAllocator().alloc(u8, sbt_size);
        try vc.device.getRayTracingShaderGroupHandlesKHR(pipeline, 0, group_count, sbt.len, sbt.ptr);

        const raygen_size = handle_size_aligned * raygen_entry_count;
        const miss_size = handle_size_aligned * miss_entry_count;
        const hit_size = handle_size_aligned * hit_entry_count;
        const callable_size = handle_size_aligned * callable_entry_count;

        // must align up to shader_group_base_alignment
        std.mem.copyBackwards(u8, sbt[callable_index..callable_index + callable_size], sbt[raygen_size + miss_size + hit_size..raygen_size + miss_size + hit_size + callable_size]);
        std.mem.copyBackwards(u8, sbt[hit_index..hit_index + hit_size], sbt[raygen_size + miss_size..raygen_size + miss_size + hit_size]);
        std.mem.copyBackwards(u8, sbt[miss_index..miss_index + miss_size], sbt[raygen_size..raygen_size + miss_size]);

        const handle = try core.mem.DeviceBuffer(u8, .{ .shader_binding_table_bit_khr = true, .transfer_dst_bit = true, .shader_device_address_bit = true }).create(vc, sbt_size, "sbt");
        errdefer handle.destroy(vc);

        handle.uploadFrom(encoder, encoder.upload_allocator.getBufferSlice(sbt));

        const raygen_address = handle.getAddress(vc);
        const miss_address = raygen_address + miss_index;
        const hit_address = raygen_address + hit_index;
        const callable_address = raygen_address + callable_index;

        return ShaderBindingTable {
            .handle = handle,

            .raygen_address = raygen_address,
            .miss_address = miss_address,
            .hit_address = hit_address,
            .callable_address = callable_address,

            .raygen_count = raygen_entry_count,
            .miss_count = miss_entry_count,
            .hit_count = hit_entry_count,
            .callable_count = callable_entry_count,

            .handle_size_aligned = handle_size_aligned,
        };
    }

    // recreate with with same table entries but new pipeline
    fn recreate(self: *ShaderBindingTable, vc: *const VulkanContext, pipeline: vk.Pipeline, encoder: *Encoder) !void {
        const rt_properties = blk: {
            var rt_properties: vk.PhysicalDeviceRayTracingPipelinePropertiesKHR = undefined;
            rt_properties.s_type = .physical_device_ray_tracing_pipeline_properties_khr;
            rt_properties.p_next = null;

            var properties2 = vk.PhysicalDeviceProperties2 {
                .properties = undefined,
                .p_next = &rt_properties,
            };

            vc.instance.getPhysicalDeviceProperties2(vc.physical_device.handle, &properties2);

            break :blk rt_properties;
        };

        const handle_size_aligned = self.handle_size_aligned;
        const group_count = self.raygen_count + self.miss_count + self.hit_count + self.callable_count;

        const raygen_index = 0;
        const miss_index = std.mem.alignForward(u32, raygen_index + self.raygen_count * handle_size_aligned, rt_properties.shader_group_base_alignment);
        const hit_index = std.mem.alignForward(u32, miss_index + self.miss_count * handle_size_aligned, rt_properties.shader_group_base_alignment);
        const callable_index = std.mem.alignForward(u32, hit_index + self.hit_count * handle_size_aligned, rt_properties.shader_group_base_alignment);
        const sbt_size = callable_index + self.callable_count * handle_size_aligned;

        // query sbt from pipeline
        const sbt = try encoder.uploadAllocator().alloc(u8, sbt_size);
        try vc.device.getRayTracingShaderGroupHandlesKHR(pipeline, 0, group_count, sbt.len, sbt.ptr);

        const raygen_size = handle_size_aligned * self.raygen_count;
        const miss_size = handle_size_aligned * self.miss_count;
        const hit_size = handle_size_aligned * self.hit_count;
        const callable_size = handle_size_aligned * self.callable_count;

        // must align up to shader_group_base_alignment
        std.mem.copyBackwards(u8, sbt[callable_index..callable_index + callable_size], sbt[raygen_size + miss_size + hit_size..raygen_size + miss_size + hit_size + callable_size]);
        std.mem.copyBackwards(u8, sbt[hit_index..hit_index + hit_size], sbt[raygen_size + miss_size..raygen_size + miss_size + hit_size]);
        std.mem.copyBackwards(u8, sbt[miss_index..miss_index + miss_size], sbt[raygen_size..raygen_size + miss_size]);

        self.handle.uploadFrom(encoder, encoder.upload_allocator.getBufferSlice(sbt));
    }

    pub fn getRaygenSBT(self: *const ShaderBindingTable) vk.StridedDeviceAddressRegionKHR {
        return vk.StridedDeviceAddressRegionKHR {
            .device_address = if (self.raygen_count != 0) self.raygen_address else 0,
            .stride = self.handle_size_aligned,
            .size = self.handle_size_aligned * self.raygen_count,
        };
    }

    pub fn getMissSBT(self: *const ShaderBindingTable) vk.StridedDeviceAddressRegionKHR {
        return vk.StridedDeviceAddressRegionKHR {
            .device_address = if (self.miss_count != 0) self.miss_address else 0,
            .stride = self.handle_size_aligned,
            .size = self.handle_size_aligned * self.miss_count,
        };
    }

    pub fn getHitSBT(self: *const ShaderBindingTable) vk.StridedDeviceAddressRegionKHR {
        return vk.StridedDeviceAddressRegionKHR {
            .device_address = if (self.hit_count != 0) self.hit_address else 0,
            .stride = self.handle_size_aligned,
            .size = self.handle_size_aligned * self.hit_count,
        };
    }

    pub fn getCallableSBT(self: *const ShaderBindingTable) vk.StridedDeviceAddressRegionKHR {
        return vk.StridedDeviceAddressRegionKHR {
            .device_address = if (self.callable_count != 0) self.callable_address else 0,
            .stride = self.handle_size_aligned,
            .size = self.handle_size_aligned * self.callable_count,
        };
    }

    fn destroy(self: *ShaderBindingTable, vc: *const VulkanContext) void {
        self.handle.destroy(vc);
    }
};
