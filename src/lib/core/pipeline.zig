const shaders = @import("shaders");
const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const descriptor = core.descriptor;

pub const supports_hot_reload = build_options.shader_source == .load;

pub const ShaderType = enum {
    ray_tracing,
    compute,
};

// creates shader modules, respecting build option to statically embed or dynamically load shader code
pub fn createShaderModule(vc: *const VulkanContext, comptime shader_path: [:0]const u8, allocator: std.mem.Allocator, comptime shader_type: ShaderType) !vk.ShaderModule {
    var to_free: []const u8 = undefined;
    defer if (supports_hot_reload) allocator.free(to_free);
    const embedded_shader = @embedFile(shader_path).*;
    const shader_code = if (!supports_hot_reload) embedded_shader else blk: {
        const compile_cmd = switch (shader_type) {
            .ray_tracing => build_options.rt_shader_compile_cmd,
            .compute => build_options.compute_shader_compile_cmd,
        };
        var compile_process = std.process.Child.init(compile_cmd ++ &[_][]const u8 { "src/lib/shaders/" ++ shader_path }, allocator);
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
    const module = try vc.device.createShaderModule(&.{
        .code_size = shader_code.len,
        .p_code = @as([*]const u32, @ptrCast(@alignCast(if (!supports_hot_reload) &shader_code else shader_code.ptr))),
    }, null);
    try core.vk_helpers.setDebugName(vc.device, module, shader_path);
    return module;
}

pub const StorageImage= struct {
    pub const descriptor_type: vk.DescriptorType = .storage_image;

    view: vk.ImageView,
};

pub const SampledImage = struct {
    pub const descriptor_type: vk.DescriptorType = .sampled_image;

    view: vk.ImageView,
};

pub const CombinedImageSampler = struct {
    pub const descriptor_type: vk.DescriptorType = .combined_image_sampler;

    view: vk.ImageView,
};

fn typeToDescriptorType(comptime T: type) vk.DescriptorType {
    if (@hasDecl(T, "descriptor_type")) return T.descriptor_type;
    return switch (T) {
        vk.AccelerationStructureKHR => .acceleration_structure_khr,
        else => @compileError("unknown descriptor type " ++ @typeName(T)),
    };
}

fn createPushDescriptorBindings(comptime Bindings: type, comptime stage_flags: vk.ShaderStageFlags) [@typeInfo(Bindings).@"struct".fields.len]descriptor.Binding {
    var bindings: [@typeInfo(Bindings).@"struct".fields.len]descriptor.Binding = undefined;
    for (@typeInfo(Bindings).@"struct".fields, &bindings) |field, *binding| {
        const descriptor_type = typeToDescriptorType(switch (@typeInfo(field.type)) {
            .optional => |optional| optional.child,
            else => field.type,
        });
        binding.* = descriptor.Binding {
            .descriptor_type = descriptor_type,
            .descriptor_count = 1,
            .stage_flags = stage_flags,
            .binding_flags = if (@typeInfo(field.type) == .optional) .{ .partially_bound_bit = true } else .{},
        };
    }

    return bindings;
}

// inline so that the temporaries here end up in the parent function
// not sure if this is part of the spec but seems to work
pub inline fn pushDescriptorDataToWriteDescriptor(BindingsType: type, bindings: BindingsType) std.BoundedArray(vk.WriteDescriptorSet, @typeInfo(BindingsType).@"struct".fields.len) {
    var writes: [@typeInfo(BindingsType).@"struct".fields.len]vk.WriteDescriptorSet = undefined;
    inline for (@typeInfo(BindingsType).@"struct".fields, &writes, 0..) |binding, *write, i| {
        const descriptor_type = comptime typeToDescriptorType(switch (@typeInfo(binding.type)) {
            .optional => |optional| optional.child,
            else => binding.type,
        });
        const binding_value = if (@typeInfo(binding.type) == .optional) @field(bindings, binding.name).? else @field(bindings, binding.name);
        write.* = switch (descriptor_type) {
            .storage_buffer => vk.WriteDescriptorSet {
                .dst_set = undefined,
                .dst_binding = i,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = descriptor_type,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                    .buffer = binding_value.handle,
                    .offset = binding_value.asBytes().offset,
                    .range = binding_value.asBytes().len,
                }),
                .p_texel_buffer_view = undefined,
            },
            .acceleration_structure_khr => vk.WriteDescriptorSet {
                .dst_set = undefined,
                .dst_binding = i,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = descriptor_type,
                .p_image_info = undefined,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
                .p_next = &vk.WriteDescriptorSetAccelerationStructureKHR {
                    .acceleration_structure_count = 1,
                    .p_acceleration_structures = @ptrCast(&binding_value),
                },
            },
            .storage_image => vk.WriteDescriptorSet {
                .dst_set = undefined,
                .dst_binding = i,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = descriptor_type,
                .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                    .sampler = .null_handle,
                    .image_view = binding_value.view,
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
                .descriptor_type = descriptor_type,
                .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                    .sampler = .null_handle,
                    .image_view = binding_value.view,
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
    var pruned_writes = std.BoundedArray(vk.WriteDescriptorSet, @typeInfo(BindingsType).@"struct".fields.len) {};
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

pub fn PipelineBindings(
    comptime name: [:0]const u8,
    comptime stages: vk.ShaderStageFlags,
    comptime PushConstants: type,
    comptime PushSetBindings: type,
    comptime additional_descriptor_layout_count: comptime_int,
) type {
    const min_vk_spec_max_push_constants_size = 128; // https://registry.khronos.org/vulkan/specs/latest/man/html/Required_Limits.html could be 256 if we require vulkan 1.4
    if (@sizeOf(PushConstants) > min_vk_spec_max_push_constants_size) @compileError(std.fmt.comptimePrint("push constant size is {}, but must be less max push constant size {} ", .{ @sizeOf(PushConstants), min_vk_spec_max_push_constants_size }));
    if (@typeInfo(PushConstants).@"struct".layout == .auto) @compileError("push constant struct layout is auto but must not be");

    const push_set_bindings = createPushDescriptorBindings(PushSetBindings, stages);
    const PushSetLayout = descriptor.DescriptorLayout(&push_set_bindings, .{ .push_descriptor_bit_khr = true }, 1, name ++ " push descriptor");

    return struct {
        push_set_layout: PushSetLayout,
        layout: vk.PipelineLayout,

        const Self = @This();

        pub const sampler_count = PushSetLayout.sampler_count;

        pub fn create(vc: *const VulkanContext, samplers: [sampler_count]vk.Sampler, additional_descriptor_layouts: [additional_descriptor_layout_count]vk.DescriptorSetLayout) !Self {
            const push_set_layout = try PushSetLayout.create(vc, samplers);
            const set_layout_handles = .{ push_set_layout.handle } ++ additional_descriptor_layouts;

            const push_constants = if (@sizeOf(PushConstants) != 0) [1]vk.PushConstantRange {
                .{
                    .offset = 0,
                    .size = @sizeOf(PushConstants),
                    .stage_flags = stages,
                }
            } else [0]vk.PushConstantRange {};
            const layout = try vc.device.createPipelineLayout(&.{
                .set_layout_count = set_layout_handles.len,
                .p_set_layouts = &set_layout_handles,
                .push_constant_range_count = push_constants.len,
                .p_push_constant_ranges = &push_constants,
            }, null);
            errdefer vc.device.destroyPipelineLayout(layout, null);
            try core.vk_helpers.setDebugName(vc.device, layout, name);

            return Self {
                .push_set_layout = push_set_layout,
                .layout = layout,
            };
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            vc.device.destroyPipelineLayout(self.layout, null);
            self.push_set_layout.destroy(vc);
        }
    };
}

pub fn Pipeline(comptime options: struct {
    shader_path: [:0]const u8,
    SpecConstants: type = extern struct {},
    PushConstants: type = extern struct {},
    PushSetBindings: type, // todo: should be specified in higher level types rather than raw vk ones
    additional_descriptor_layout_count: comptime_int = 0,
}) type {
    if (@typeInfo(options.SpecConstants).@"struct".layout == .auto) @compileError("specialization constant struct layout is auto but must not be");

    return struct {
        bindings: Bindings,
        handle: vk.Pipeline,

        const Self = @This();

        const Bindings = PipelineBindings(options.shader_path, .{ .compute_bit = true }, options.PushConstants, options.PushSetBindings, options.additional_descriptor_layout_count);

        pub const SpecConstants = options.SpecConstants;
        pub const PushSetBindings = options.PushSetBindings;

        pub fn create(vc: *const VulkanContext, allocator: std.mem.Allocator, constants: SpecConstants, samplers: [Bindings.sampler_count]vk.Sampler, additional_descriptor_layouts: [options.additional_descriptor_layout_count]vk.DescriptorSetLayout) !Self {
            var bindings = try Bindings.create(vc, samplers, additional_descriptor_layouts);
            errdefer bindings.destroy(vc);

            var self = Self {
                .bindings = bindings,
                .handle = undefined,
            };

            _ = try self.recreate(vc, allocator, constants);

            return self;
        }

        // returns old handle which must be cleaned up
        pub fn recreate(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, constants: SpecConstants) !vk.Pipeline {
            const module = try createShaderModule(vc, options.shader_path, allocator, .compute);
            defer vc.device.destroyShaderModule(module, null);

            var stage = vk.PipelineShaderStageCreateInfo {
                .module = module,
                .p_name = "main",
                .stage = .{ .compute_bit = true },
            };

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

                stage.p_specialization_info = &vk.SpecializationInfo {
                    .map_entry_count = map_entries.len,
                    .p_map_entries = &map_entries,
                    .data_size = @sizeOf(SpecConstants),
                    .p_data = &constants,
                };
            }

            const create_info = vk.ComputePipelineCreateInfo {
                .stage = stage,
                .layout = self.bindings.layout,
                .base_pipeline_handle = .null_handle,
                .base_pipeline_index = -1,
            };

            const old_handle = self.handle;
            _ = try vc.device.createComputePipelines(.null_handle, 1, @ptrCast(&create_info), null, @ptrCast(&self.handle));
            errdefer vc.device.destroyPipeline(self.handle, null);
            try core.vk_helpers.setDebugName(vc.device, self.handle, options.shader_path);

            return old_handle;
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            vc.device.destroyPipeline(self.handle, null);
            self.bindings.destroy(vc);
        }

        pub fn recordBindPipeline(self: *const Self, command_buffer: VulkanContext.CommandBuffer) void {
            command_buffer.bindPipeline(.compute, self.handle);
        }

        pub fn recordDispatch(self: *const Self, command_buffer: VulkanContext.CommandBuffer, extent: vk.Extent3D) void {
            _ = self;
            command_buffer.dispatch(extent.width, extent.height, extent.depth);
        }

        pub usingnamespace if (options.additional_descriptor_layout_count != 0) struct {
            pub fn recordBindAdditionalDescriptorSets(self: *const Self, command_buffer: VulkanContext.CommandBuffer, sets: [options.additional_descriptor_layout_count]vk.DescriptorSet) void {
                command_buffer.bindDescriptorSets(.compute, self.bindings.layout, 1, sets.len, &sets, 0, undefined);
            }
        } else struct {};

        pub usingnamespace if (@sizeOf(options.PushConstants) != 0) struct {
            pub fn recordPushConstants(self: *const Self, command_buffer: VulkanContext.CommandBuffer, constants: options.PushConstants) void {
                const bytes = std.mem.asBytes(&constants);
                command_buffer.pushConstants(self.bindings.layout, .{ .compute_bit = true }, 0, bytes.len, bytes);
            }
        } else struct {};

        pub fn recordPushDescriptors(self: *const Self, command_buffer: VulkanContext.CommandBuffer, bindings: options.PushSetBindings) void {
            const writes = pushDescriptorDataToWriteDescriptor(options.PushSetBindings, bindings);
            command_buffer.pushDescriptorSetKHR(.compute, self.bindings.layout, 0, @intCast(writes.len), &writes.buffer);
        }
    };
}
