const shaders = @import("shaders");
const vk = @import("vulkan");
const std = @import("std");
const build_options = @import("build_options");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Commands = core.Commands;
const VkAllocator = core.Allocator;
const descriptor = core.descriptor;

pub const ShaderType = enum {
    ray_tracing,
    compute,
};

// creates shader modules, respecting build option to statically embed or dynamically load shader code
pub fn createShaderModule(vc: *const VulkanContext, comptime shader_path: []const u8, allocator: std.mem.Allocator, comptime shader_type: ShaderType) !vk.ShaderModule {
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

pub fn CreatePushDescriptorDataType(comptime bindings: []const descriptor.DescriptorBindingInfo) type {
    var fields: [bindings.len]std.builtin.Type.StructField = undefined;
    for (bindings, &fields) |binding, *field| {
        const InnerType = switch (binding.descriptor_type) {
            .storage_buffer => vk.Buffer,
            .acceleration_structure_khr => vk.AccelerationStructureKHR,
            .storage_image, .combined_image_sampler, .sampled_image => vk.ImageView,
            else => @compileError("unknown descriptor type " ++ @tagName(binding.descriptor_type)), // TODO
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
    return @Type(info);
}

// this really should be a member function of the above -- hope zig lets me do that eventually
//
// inline so that the temporaries here end up in the parent function
// not sure if this is part of the spec but seems to work
pub inline fn pushDescriptorDataToWriteDescriptor(comptime bindings: []const descriptor.DescriptorBindingInfo, data: CreatePushDescriptorDataType(bindings)) std.BoundedArray(vk.WriteDescriptorSet, bindings.len) {
    var writes: [bindings.len]vk.WriteDescriptorSet = undefined;
    inline for (bindings, &writes, 0..) |binding, *write, i| {
        write.* = switch (binding.descriptor_type) {
            .storage_buffer => vk.WriteDescriptorSet {
                .dst_set = undefined,
                .dst_binding = i,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = binding.descriptor_type,
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
                .descriptor_type = binding.descriptor_type,
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
                .descriptor_type = binding.descriptor_type,
                .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                    .sampler = .null_handle,
                    .image_view = @field(data, binding.name),
                    .image_layout = .general,
                }),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            .combined_image_sampler, .sampled_image => vk.WriteDescriptorSet {
                .dst_set = undefined,
                .dst_binding = i,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = binding.descriptor_type,
                .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                    .sampler = .null_handle,
                    .image_view = @field(data, binding.name),
                    .image_layout = .shader_read_only_optimal,
                }),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            else => @compileError("unknown descriptor type " ++ @tagName(binding.descriptor_type)), // TODO
        };
    }

    // remove any writes we may not actually want, e.g.,
    // samplers or zero-size things
    var pruned_writes = std.BoundedArray(vk.WriteDescriptorSet, bindings.len) {};
    for (writes) |write| {
        if (write.descriptor_type == .sampler) continue;
        if (write.descriptor_count == 0) continue;
        switch (write.descriptor_type) {
            .storage_buffer => if (write.p_buffer_info[0].buffer == .null_handle) continue,
            else => {},
        }
        pruned_writes.append(write) catch unreachable;
    }

    return pruned_writes;
}

pub fn Pipeline(
        comptime shader_path: []const u8,
        comptime SpecConstantsT: type,
        comptime PushConstants: type,
        comptime push_set_bindings: []const descriptor.DescriptorBindingInfo,
    ) type {

    return struct {
        push_set_layout: PushSetLayout,
        layout: vk.PipelineLayout,
        handle: vk.Pipeline,

        const Self = @This();

        pub const SpecConstants = SpecConstantsT;

        pub const PushDescriptorData = CreatePushDescriptorDataType(push_set_bindings);

        const PushSetLayout = descriptor.DescriptorLayout(push_set_bindings, .{ .push_descriptor_bit_khr = true }, 1, shader_path ++ " push descriptor");

        pub fn create(vc: *const VulkanContext, allocator: std.mem.Allocator, constants: SpecConstants, samplers: [PushSetLayout.sampler_count]vk.Sampler) !Self {
            const push_set_layout = try PushSetLayout.create(vc, samplers);
            const set_layout_handles = [1]vk.DescriptorSetLayout { push_set_layout.handle };

            const push_constants = if (@sizeOf(PushConstants) != 0) [1]vk.PushConstantRange {
                .{
                    .offset = 0,
                    .size = @sizeOf(PushConstants),
                    .stage_flags = .{ .compute_bit = true },
                }
            } else [0]vk.PushConstantRange {};
            const layout = try vc.device.createPipelineLayout(&.{
                .set_layout_count = set_layout_handles.len,
                .p_set_layouts = &set_layout_handles,
                .push_constant_range_count = push_constants.len,
                .p_push_constant_ranges = &push_constants,
            }, null);
            errdefer vc.device.destroyPipelineLayout(layout, null);

            var self = Self {
                .push_set_layout = push_set_layout,
                .layout = layout,
                .handle = undefined,
            };

            _ = try self.recreate(vc, allocator, constants);

            return self;
        }

        // returns old handle which must be cleaned up
        pub fn recreate(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, constants: SpecConstants) !vk.Pipeline {
            const module = try createShaderModule(vc, shader_path, allocator, .compute);
            defer vc.device.destroyShaderModule(module, null);

            var stage = vk.PipelineShaderStageCreateInfo {
                .module = module,
                .p_name = "main",
                .stage = .{ .compute_bit = true },
            };

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

                stage.p_specialization_info = &vk.SpecializationInfo {
                    .map_entry_count = map_entries.len,
                    .p_map_entries = &map_entries,
                    .data_size = @sizeOf(SpecConstants),
                    .p_data = &constants,
                };
            }

            const create_info = vk.ComputePipelineCreateInfo {
                .stage = stage,
                .layout = self.layout,
                .base_pipeline_handle = .null_handle,
                .base_pipeline_index = -1,
            };

            const old_handle = self.handle;
            _ = try vc.device.createComputePipelines(.null_handle, 1, @ptrCast(&create_info), null, @ptrCast(&self.handle));
            errdefer vc.device.destroyPipeline(self.handle, null);

            return old_handle;
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            vc.device.destroyPipelineLayout(self.layout, null);
            vc.device.destroyPipeline(self.handle, null);
            self.push_set_layout.destroy(vc);
        }

        pub fn recordBindPipeline(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer) void {
            vc.device.cmdBindPipeline(command_buffer, .compute, self.handle);
        }

        pub fn recordDispatch(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, extent: vk.Extent3D) void {
            _ = self;
            vc.device.cmdDispatch(command_buffer, extent.width, extent.height, extent.depth);
        }

        pub usingnamespace if (@sizeOf(PushConstants) != 0) struct {
            pub fn recordPushConstants(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, constants: PushConstants) void {
                const bytes = std.mem.asBytes(&constants);
                vc.device.cmdPushConstants(command_buffer, self.layout, .{ .compute_bit = true }, 0, bytes.len, bytes);
            }
        } else struct {};

        pub fn recordPushDescriptors(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, data: PushDescriptorData) void {
            const writes = pushDescriptorDataToWriteDescriptor(push_set_bindings, data);
            vc.device.cmdPushDescriptorSetKHR(command_buffer, .compute, self.layout, 0, writes.len, &writes.buffer);
        }
    };
}
