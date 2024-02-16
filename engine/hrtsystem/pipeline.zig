const shaders = @import("shaders");
const vk = @import("vulkan");
const std = @import("std");
const build_options = @import("build_options");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Commands = core.Commands;
const VkAllocator = core.Allocator;
const DestructionQueue = core.DestructionQueue;
const descriptor = core.descriptor;

const Camera = @import("./Camera.zig");

const SceneDescriptorLayout = engine.hrtsystem.Scene.DescriptorLayout;
const InputDescriptorLayout = engine.hrtsystem.ObjectPicker.DescriptorLayout;
const TextureDescriptorLayout = engine.hrtsystem.MaterialManager.TextureManager.DescriptorLayout;

const vector = engine.vector;
const F32x2 = vector.Vec2(f32);
const F32x3 = vector.Vec3(f32);

const ShaderType = enum {
    ray_tracing,
    compute,
};

// creates shader modules, respecting build option to statically embed or dynamically load shader code
fn createShaderModule(vc: *const VulkanContext, comptime shader_path: []const u8, allocator: std.mem.Allocator, comptime shader_type: ShaderType) !vk.ShaderModule {
    var to_free: []const u8 = undefined;
    defer if (build_options.shader_source == .load) allocator.free(to_free);
    const shader_code = if (build_options.shader_source == .embed) switch (shader_type) {
            .ray_tracing => @field(@import("rt_shaders"), shader_path),
            .compute => @field(@import("compute_shaders"), shader_path),
        } else blk: {
        const compile_cmd = switch (shader_type) {
            .ray_tracing => build_options.rt_shader_compile_cmd,
            .compute => build_options.compute_shader_compile_cmd,
        };
        var compile_process = std.ChildProcess.init(compile_cmd ++ &[_][]const u8 { "shaders/" ++ shader_path }, allocator);
        compile_process.stdout_behavior = .Pipe;
        try compile_process.spawn();
        const stdout = blk_inner: {
            var poller = std.io.poll(allocator, enum { stdout }, .{ .stdout = compile_process.stdout.? });
            defer poller.deinit();

            while (try poller.poll()) {}

            var fifo = poller.fifo(.stdout);
            if (fifo.head > 0) {
                @memcpy(fifo.buf[0..fifo.count], fifo.buf[fifo.head .. fifo.head + fifo.count]);
            }

            to_free = fifo.buf;
            const stdout = fifo.buf[0..fifo.count];
            fifo.* = std.io.PollFifo.init(allocator);

            break :blk_inner stdout;
        };

        const term = try compile_process.wait();
        if (term == .Exited and term.Exited != 0) return error.ShaderCompileFail;
        break :blk stdout;
    };
    return try vc.device.createShaderModule(&.{
        .code_size = shader_code.len,
        .p_code = @as([*]const u32, @ptrCast(@alignCast(if (build_options.shader_source == .embed) &shader_code else shader_code.ptr))),
    }, null);
}

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

pub fn Pipeline(
        comptime shader_name: []const u8,
        comptime SpecConstantsT: type,
        comptime PushConstants: type,
        comptime has_textures: bool,
        comptime push_set_bindings: []const descriptor.DescriptorBindingInfo,
        comptime stages: []const Stage,
    ) type {

    return struct {
        push_set_layout: PushSetLayout,
        layout: vk.PipelineLayout,
        handle: vk.Pipeline,
        sbt: ShaderBindingTable,

        const Self = @This();

        pub const SpecConstants = SpecConstantsT;

        pub const PushDescriptorData = blk: {
            var fields: [push_set_bindings.len]std.builtin.Type.StructField = undefined;
            for (push_set_bindings, &fields) |binding, *field| {
                const InnerType = switch (binding.descriptor_type) {
                    .storage_buffer => vk.Buffer,
                    .acceleration_structure_khr => vk.AccelerationStructureKHR,
                    .storage_image => vk.ImageView,
                    .combined_image_sampler => vk.ImageView,
                    else => unreachable, // TODO
                };
                field.* = std.builtin.Type.StructField {
                    .name = binding.name,
                    .type = InnerType,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(InnerType),
                };
            }

            const info = std.builtin.Type {
                .Struct = std.builtin.Type.Struct {
                    .fields = &fields,
                    .layout = .Auto,
                    .decls = &.{},
                    .is_tuple = false,
                },
            };
            break :blk @Type(info);
        };

        const PushSetLayout = descriptor.DescriptorLayout(push_set_bindings, .{ .push_descriptor_bit_khr = true }, 1, shader_name ++ " push descriptor");

        pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, cmd: *Commands, texture_layout: if (has_textures) TextureDescriptorLayout else void, constants: SpecConstants, samplers: [PushSetLayout.sampler_count]vk.Sampler) !Self {
            const push_set_layout = try PushSetLayout.create(vc, samplers);
            const set_layout_handles = if (has_textures) [2]vk.DescriptorSetLayout {
                texture_layout.handle,
                push_set_layout.handle,
            } else [1]vk.DescriptorSetLayout { push_set_layout.handle };

            const push_constants = if (@sizeOf(PushConstants) != 0) [1]vk.PushConstantRange {
                .{
                    .offset = 0,
                    .size = @sizeOf(PushConstants),
                    .stage_flags = .{ .raygen_bit_khr = true }, // push constants only for raygen
                }
            } else .{};
            const layout = try vc.device.createPipelineLayout(&.{
                .set_layout_count = set_layout_handles.len,
                .p_set_layouts = &set_layout_handles,
                .push_constant_range_count = push_constants.len,
                .p_push_constant_ranges = &push_constants,
            }, null);
            errdefer vc.device.destroyPipelineLayout(layout, null);

            const module = try createShaderModule(vc, "hrtsystem/" ++ shader_name ++ ".hlsl", allocator, .ray_tracing);
            defer vc.device.destroyShaderModule(module, null);

            var vk_stages: [stages.len]vk.PipelineShaderStageCreateInfo = undefined;
            var vk_groups: [stages.len]vk.RayTracingShaderGroupCreateInfoKHR = undefined;
            inline for (stages, &vk_stages, &vk_groups, 0..) |stage, *vk_stage, *vk_group, i| {
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
                const inner_fields = @typeInfo(SpecConstants).Struct.fields;
                var map_entries: [inner_fields.len]vk.SpecializationMapEntry = undefined;
                inline for (&map_entries, inner_fields, 0..) |*map_entry, inner_field, j| {
                    map_entry.* = vk.SpecializationMapEntry {
                        .constant_id = j,
                        .offset = @offsetOf(SpecConstants, inner_field.name),
                        .size = inner_field.alignment,
                    };
                }

                for (stages, &vk_stages) |stage, *vk_stage|{
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
                .layout = layout,
                .base_pipeline_handle = .null_handle,
                .base_pipeline_index = -1,
            };
            var handle: vk.Pipeline = undefined;
            _ = try vc.device.createRayTracingPipelinesKHR(.null_handle, .null_handle, 1, @ptrCast(&create_info), null, @ptrCast(&handle));
            errdefer vc.device.destroyPipeline(handle, null);

            const shader_info = comptime ShaderInfo.find(stages);
            const sbt = try ShaderBindingTable.create(vc, vk_allocator, allocator, handle, cmd, shader_info.raygen_count, shader_info.miss_count, shader_info.hit_count, shader_info.callable_count);
            errdefer sbt.destroy(vc);

            return Self {
                .push_set_layout = push_set_layout,
                .layout = layout,
                .handle = handle,

                .sbt = sbt,
            };
        }

        // returns old handle which must be cleaned up
        pub fn recreate(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, cmd: *Commands, constants: SpecConstants) !vk.Pipeline {
            const module = try createShaderModule(vc, "hrtsystem/" ++ shader_name ++ ".hlsl", allocator, .ray_tracing);
            defer vc.device.destroyShaderModule(module, null);

            var vk_stages: [stages.len]vk.PipelineShaderStageCreateInfo = undefined;
            var vk_groups: [stages.len]vk.RayTracingShaderGroupCreateInfoKHR = undefined;
            inline for (stages, &vk_stages, &vk_groups, 0..) |stage, *vk_stage, *vk_group, i| {
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
                const inner_fields = @typeInfo(SpecConstants).Struct.fields;
                var map_entries: [inner_fields.len]vk.SpecializationMapEntry = undefined;
                inline for (&map_entries, inner_fields, 0..) |*map_entry, inner_field, j| {
                    map_entry.* = vk.SpecializationMapEntry {
                        .constant_id = j,
                        .offset = @offsetOf(SpecConstants, inner_field.name),
                        .size = inner_field.alignment, // not completely sure this is right -- purpose is so that e.g., we can have a 32 bit bool. should work.
                    };
                }

                for (stages, &vk_stages) |stage, *vk_stage|{
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
                .layout = self.layout,
                .base_pipeline_handle = .null_handle,
                .base_pipeline_index = -1,
            };
            const old_handle = self.handle;
            _ = try vc.device.createRayTracingPipelinesKHR(.null_handle, .null_handle, 1, @ptrCast(&create_info), null, @ptrCast(&self.handle));
            errdefer vc.device.destroyPipeline(self.handle, null);

            try self.sbt.recreate(vc, vk_allocator, self.handle, cmd);

            return old_handle;
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            self.sbt.destroy(vc);
            vc.device.destroyPipelineLayout(self.layout, null);
            vc.device.destroyPipeline(self.handle, null);
            self.push_set_layout.destroy(vc);
        }

        pub fn recordBindPipeline(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer) void {
            vc.device.cmdBindPipeline(command_buffer, .ray_tracing_khr, self.handle);
        }

        pub fn recordBindTextureDescriptorSet(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, set: vk.DescriptorSet) void {
            vc.device.cmdBindDescriptorSets(command_buffer, .ray_tracing_khr, self.layout, 0, 1, &[_]vk.DescriptorSet { set }, 0, undefined);
        }

        pub fn recordTraceRays(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, extent: vk.Extent2D) void {
            vc.device.cmdTraceRaysKHR(command_buffer, &self.sbt.getRaygenSBT(), &self.sbt.getMissSBT(), &self.sbt.getHitSBT(), &self.sbt.getCallableSBT(), extent.width, extent.height, 1);
        }

        pub fn recordPushConstants(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, constants: PushConstants) void {
            const bytes = std.mem.asBytes(&constants);
            vc.device.cmdPushConstants(command_buffer, self.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);
        }

        pub fn recordPushDescriptors(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, data: PushDescriptorData) void {
            // create vk.WriteDescriptorSet from PushDescriptorData
            var writes: [push_set_bindings.len]vk.WriteDescriptorSet = undefined;
            inline for (push_set_bindings, &writes, 0..) |binding, *write, i| {
                write.* = switch (binding.descriptor_type) {
                    .storage_buffer => vk.WriteDescriptorSet {
                        .dst_set = undefined,
                        .dst_binding = i,
                        .dst_array_element = 0,
                        .descriptor_count = 1,
                        .descriptor_type = .storage_buffer,
                        .p_image_info = undefined,
                        .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                            .buffer = @field(data, binding.name),
                            .offset = 0,
                            .range = vk.WHOLE_SIZE,
                        }),
                        .p_texel_buffer_view = undefined,
                    },
                    .acceleration_structure_khr => vk.WriteDescriptorSet {
                        .dst_set = undefined,
                        .dst_binding = i,
                        .dst_array_element = 0,
                        .descriptor_count = 1,
                        .descriptor_type = .acceleration_structure_khr,
                        .p_image_info = undefined,
                        .p_buffer_info = undefined,
                        .p_texel_buffer_view = undefined,
                        .p_next = &vk.WriteDescriptorSetAccelerationStructureKHR {
                            .acceleration_structure_count = 1,
                            .p_acceleration_structures = @ptrCast(&@field(data, binding.name)),
                        },
                    },
                    .storage_image => vk.WriteDescriptorSet {
                        .dst_set = undefined,
                        .dst_binding = i,
                        .dst_array_element = 0,
                        .descriptor_count = 1,
                        .descriptor_type = .storage_image,
                        .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                            .sampler = .null_handle,
                            .image_view = @field(data, binding.name),
                            .image_layout = .general,
                        }),
                        .p_buffer_info = undefined,
                        .p_texel_buffer_view = undefined,
                    },
                    .combined_image_sampler => vk.WriteDescriptorSet {
                        .dst_set = undefined,
                        .dst_binding = i,
                        .dst_array_element = 0,
                        .descriptor_count = 1,
                        .descriptor_type = .combined_image_sampler,
                        .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                            .sampler = .null_handle,
                            .image_view = @field(data, binding.name),
                            .image_layout = .shader_read_only_optimal,
                        }),
                        .p_buffer_info = undefined,
                        .p_texel_buffer_view = undefined,
                    },
                    else => unreachable, // TODO
                };
            }

            // remove any writes we may not actually want, e.g.,
            // samplers or zero-size things
            var pruned_writes = std.BoundedArray(vk.WriteDescriptorSet, push_set_bindings.len) {};
            for (writes) |write| {
                if (write.descriptor_type == .sampler) continue;
                if (write.descriptor_count == 0) continue;
                switch (write.descriptor_type) {
                    .storage_buffer => if (write.p_buffer_info[0].buffer == .null_handle) continue,
                    else => {},
                }
                pruned_writes.append(write) catch unreachable;
            }

            vc.device.cmdPushDescriptorSetKHR(command_buffer, .ray_tracing_khr, self.layout, if (has_textures) 1 else 0, pruned_writes.len, &pruned_writes.buffer);
        }
    };
}

pub const ObjectPickPipeline = Pipeline(
    "input",
    extern struct {},
    extern struct {
        lens: Camera.Lens,
        click_position: F32x2,
    },
    false,
    &.{
        .{
            .name = "tlas",
            .descriptor_type = .acceleration_structure_khr,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
        },
        .{
            .name = "output_image",
            .descriptor_type = .storage_image,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
        },
        .{
            .name = "click_data",
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
        },
    },
    &[_]Stage {
        .{ .type = .raygen, .entrypoint = "raygen" },
        .{ .type = .miss, .entrypoint = "miss" },
        .{ .type = .closest_hit, .entrypoint = "closesthit" },
    }
);

// a "standard" pipeline -- that is, the one we use for most
// rendering operations
pub const StandardPipeline = Pipeline(
    "main",
    extern struct {
        samples_per_run: u32 = 1,
        max_bounces: u32 = 4,
        env_samples_per_bounce: u32 = 1,
        mesh_samples_per_bounce: u32 = 1,
        flip_image: bool align(@alignOf(vk.Bool32)) = true,
    },
    extern struct {
        lens: Camera.Lens,
        sample_count: u32,
    },
    true,
    &.{
        .{
            .name = "tlas",
            .descriptor_type = .acceleration_structure_khr,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
            .binding_flags = .{ .partially_bound_bit = true },
        },
        .{
            .name = "instances",
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
            .binding_flags = .{ .partially_bound_bit = true },
        },
        .{
            .name = "world_to_instances",
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
            .binding_flags = .{ .partially_bound_bit = true },
        },
        .{
            .name = "emitter_alias_table",
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
            .binding_flags = .{ .partially_bound_bit = true },
        },
        .{
            .name = "meshes",
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
            .binding_flags = .{ .partially_bound_bit = true },
        },
        .{
            .name = "geometries",
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
            .binding_flags = .{ .partially_bound_bit = true },
        },
        .{
            .name = "material_values",
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
            .binding_flags = .{ .partially_bound_bit = true },
        },
        .{
            .name = "background_image",
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
        },
        .{
            .name = "background_marginal_alias",
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
        },
        .{
            .name = "background_conditional_alias",
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
        },
        .{
            .name = "output_image",
            .descriptor_type = .storage_image,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true },
        },
    },
    &[_]Stage {
        .{ .type = .raygen, .entrypoint = "raygen" },
        .{ .type = .miss, .entrypoint = "miss" },
        .{ .type = .miss, .entrypoint = "shadowmiss" },
        .{ .type = .closest_hit, .entrypoint = "closesthit" },
    }
);

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

// TODO: maybe use vkCmdUploadBuffer here
const ShaderBindingTable = struct {
    handle: VkAllocator.DeviceBuffer(u8),

    raygen_address: vk.DeviceAddress,
    miss_address: vk.DeviceAddress,
    hit_address: vk.DeviceAddress,
    callable_address: vk.DeviceAddress,

    raygen_count: u32,
    miss_count: u32,
    hit_count: u32,
    callable_count: u32,

    handle_size_aligned: u32,

    fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, pipeline: vk.Pipeline, cmd: *Commands, raygen_entry_count: u32, miss_entry_count: u32, hit_entry_count: u32, callable_entry_count: u32) !ShaderBindingTable {
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
        const sbt = try vk_allocator.createHostBuffer(vc, u8, sbt_size, .{ .transfer_src_bit = true });
        defer sbt.destroy(vc);
        try vc.device.getRayTracingShaderGroupHandlesKHR(pipeline, 0, group_count, sbt.data.len, sbt.data.ptr);

        const raygen_size = handle_size_aligned * raygen_entry_count;
        const miss_size = handle_size_aligned * miss_entry_count;
        const hit_size = handle_size_aligned * hit_entry_count;
        const callable_size = handle_size_aligned * callable_entry_count;

        // must align up to shader_group_base_alignment
        std.mem.copyBackwards(u8, sbt.data[callable_index..callable_index + callable_size], sbt.data[raygen_size + miss_size + hit_size..raygen_size + miss_size + hit_size + callable_size]);
        std.mem.copyBackwards(u8, sbt.data[hit_index..hit_index + hit_size], sbt.data[raygen_size + miss_size..raygen_size + miss_size + hit_size]);
        std.mem.copyBackwards(u8, sbt.data[miss_index..miss_index + miss_size], sbt.data[raygen_size..raygen_size + miss_size]);

        const handle = try vk_allocator.createDeviceBuffer(vc, allocator, u8, sbt_size, .{ .shader_binding_table_bit_khr = true, .transfer_dst_bit = true, .shader_device_address_bit = true });
        errdefer handle.destroy(vc);

        try cmd.startRecording(vc);
        cmd.recordUploadBuffer(u8, vc, handle, sbt);
        try cmd.submit(vc);

        const raygen_address = handle.getAddress(vc);
        const miss_address = raygen_address + miss_index;
        const hit_address = raygen_address + hit_index;
        const callable_address = raygen_address + callable_index;

        try cmd.idleUntilDone(vc);

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
    fn recreate(self: *ShaderBindingTable, vc: *const VulkanContext, vk_allocator: *VkAllocator, pipeline: vk.Pipeline, cmd: *Commands) !void {
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
        const sbt = try vk_allocator.createHostBuffer(vc, u8, sbt_size, .{ .transfer_src_bit = true });
        defer sbt.destroy(vc);
        try vc.device.getRayTracingShaderGroupHandlesKHR(pipeline, 0, group_count, sbt.data.len, sbt.data.ptr);

        const raygen_size = handle_size_aligned * self.raygen_count;
        const miss_size = handle_size_aligned * self.miss_count;
        const hit_size = handle_size_aligned * self.hit_count;
        const callable_size = handle_size_aligned * self.callable_count;

        // must align up to shader_group_base_alignment
        std.mem.copyBackwards(u8, sbt.data[callable_index..callable_index + callable_size], sbt.data[raygen_size + miss_size + hit_size..raygen_size + miss_size + hit_size + callable_size]);
        std.mem.copyBackwards(u8, sbt.data[hit_index..hit_index + hit_size], sbt.data[raygen_size + miss_size..raygen_size + miss_size + hit_size]);
        std.mem.copyBackwards(u8, sbt.data[miss_index..miss_index + miss_size], sbt.data[raygen_size..raygen_size + miss_size]);

        try cmd.startRecording(vc);
        cmd.recordUploadBuffer(u8, vc, self.handle, sbt);
        try cmd.submitAndIdleUntilDone(vc);
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
