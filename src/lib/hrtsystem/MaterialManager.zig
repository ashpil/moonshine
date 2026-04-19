const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const Image = core.Image;
const vk_helpers = core.vk_helpers;

const F32x2 = engine.vector.Vec2(f32);
const F32x3 = engine.vector.Vec3(f32);

// I define a material to be a BSDF that may vary over a surface,
// plus a normal and emissive map
pub const Material = struct {
    // on the host side, materials are represented as a regular tagged union
    pub const Parameters = struct {
        pub const default_normal = F32x2.new(.{ 0.5, 0.5 });
        const normal_components = @TypeOf(default_normal).element_count;
        const emissive_components = 3;

        name: []const u8,

        normal: TextureManager.Handle,
        emissive: TextureManager.Handle,

        volume: Volume = .{},

        bsdf: PolymorphicBSDF,
    };

    // since GPUs do not support tagged unions, we solve this with a little indirection,
    // translating this into a GPU buffer for each variant, and have a base material struct
    // that simply has an enum and a device address, which points to the specific variant
    pub const Device = extern struct {
        normal: TextureManager.Handle,
        emissive: TextureManager.Handle,

        volume: Volume,

        type: BSDF = .standard_pbr,
        addr: vk.DeviceAddress,
    };
};

pub const Volume = extern struct {
    medium: Medium = .{},
    phase: HenyeyGreenstein = .{},
    ior: CauchyIOR = .{},
};

pub const CauchyIOR = extern struct {
    a: f32 = 1.0,
    b: f32 = 0.0,

    pub fn fromAbbeNumberAndIOR(abbe_number: f32, ior: f32) CauchyIOR {
        const fraunhofer_F = 486.13;
        const fraunhofer_d = 587.56;
        const fraunhofer_C = 656.27;

        const b = (ior - 1.0) / (abbe_number * (std.math.pow(f32, fraunhofer_F, -2.0) - std.math.pow(f32, fraunhofer_C, -2.0)));
        const a = ior - (b / std.math.pow(f32, fraunhofer_d, 2.0));

        return CauchyIOR {
            .a = a,
            .b = b,
        };
    }
};

pub const HenyeyGreenstein = extern struct {
    g: f32 = 0.0,
};

pub const Medium = extern struct {
    @"σ_s": F32x3 = F32x3.new(.{0, 0, 0}),
    @"σ_a": F32x3 = F32x3.new(.{0, 0, 0}),
};

pub const BSDF = enum(u32) {
    glass,
    lambert,
    perfect_mirror,
    standard_pbr,
};

// technically these are BSDF parameters rather than
// BSDFs themselves, as BSDFs do not very over a surface
// but these textures do
pub const PolymorphicBSDF = union(BSDF) {
    glass: void,
    lambert: Lambert,
    perfect_mirror: void, // no payload
    standard_pbr: StandardPBR,
};

pub const StandardPBR = extern struct {
    const color_components = 3;
    const metalness_components = 1;
    const roughness_components = 1;

    color: TextureManager.Handle,
    metalness: TextureManager.Handle,
    roughness: TextureManager.Handle,
    ior: CauchyIOR = CauchyIOR {
        .a = 1.5,
        .b = 0,
    },
};

pub const Lambert = extern struct {
    const color_components = 3;
    color: TextureManager.Handle,
};

// takes in a tagged union and returns a struct that has each of the union fields as a field,
// with type InnerFn(field)
//
// sometimes I have a little too much fun with metaprogramming
fn StructFromTaggedUnion(comptime Union: type, comptime InnerFn: fn(type) type) type {
    if (@typeInfo(Union) != .@"union") @compileError(@typeName(Union) ++ " must be a union, but is not");
    const variants = @typeInfo(Union).@"union".fields;
    comptime var field_names: [variants.len][]const u8 = undefined;
    comptime var field_types: [variants.len]type = undefined;
    comptime var field_attrs: [variants.len]std.builtin.Type.StructField.Attributes = undefined;
    for (&field_names, &field_types, &field_attrs, variants) |*name, *t, *attr, variant| {
        const T = InnerFn(variant.type);
        name.* = variant.name;
        t.* = T;
        attr.* = .{
            .default_value_ptr = &T {},
        };
    }
    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

fn VariantBuffer(comptime T: type) type {
    return struct {
        buffer: core.mem.DeviceBuffer(T, .{ .shader_device_address_bit = true, .transfer_dst_bit = true }) = .{},
        addr: vk.DeviceAddress = 0,
        len: vk.DeviceSize = 0,
    };
}

const VariantBuffers = StructFromTaggedUnion(PolymorphicBSDF, VariantBuffer);

material_count: u32,
textures: TextureManager,
materials: core.mem.DeviceBuffer(Material.Device, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }),

variant_buffers: VariantBuffers,

pub const Handle = u32;

const Self = @This();

const max_materials = 2048; // TODO: resizable buffers

pub fn createEmpty(vc: *const VulkanContext) !Self {
    return Self {
        .material_count = 0,
        .materials = .{},
        .variant_buffers = .{},
        .textures = try TextureManager.create(vc),
    };
}

// you can either do this or create below, but not both
// texture handles must've been already added to the MaterialManager's textures
pub fn upload(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, parameters: Material.Parameters) !Handle {
    std.debug.assert(self.material_count < max_materials);

    inline for (@typeInfo(PolymorphicBSDF).@"union".fields, 0..) |field, field_idx| {
        if (@as(BSDF, @enumFromInt(field_idx)) == std.meta.activeTag(parameters.bsdf)) {
            if (@sizeOf(field.type) != 0) {
                const variant_buffer = &@field(self.variant_buffers, field.name);
                if (variant_buffer.buffer.isNull()) {
                    const buffer_name = try std.fmt.allocPrintSentinel(allocator, "material {s} {s}", .{ parameters.name, field.name }, 0);
                    defer allocator.free(buffer_name);
                    variant_buffer.buffer = try core.mem.DeviceBuffer(field.type, .{ .shader_device_address_bit = true, .transfer_dst_bit = true }).create(vc, max_materials, buffer_name);
                    variant_buffer.addr = variant_buffer.buffer.getAddress(vc);
                }
                variant_buffer.buffer.updateFrom(encoder, variant_buffer.len, &.{ @field(parameters.bsdf, field.name) });
                variant_buffer.len += 1;
            }

            const material = Material.Device {
                .normal = parameters.normal,
                .emissive = parameters.emissive,
                .volume = parameters.volume,
                .type = std.meta.activeTag(parameters.bsdf),
                .addr = if (@sizeOf(field.type) != 0) @field(self.variant_buffers, field.name).addr + (@field(self.variant_buffers, field.name).len - 1) * @sizeOf(field.type) else 0,
            };
            if (self.materials.isNull()) self.materials = try core.mem.DeviceBuffer(Material.Device, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, max_materials, "materials");
            self.materials.updateFrom(encoder, self.material_count, &.{ material });
        }
    }

    self.material_count += 1;
    return self.material_count - 1;
}

pub fn recordUpdateSingleMaterial(self: *Self, command_buffer: VulkanContext.CommandBuffer, material: Handle, value: Material.Device) void {
    const offset = @sizeOf(Material.Device) * material;
    const size = @sizeOf(Material.Device);
    command_buffer.updateBuffer(self.materials.handle, offset, size, &value);

    command_buffer.pipelineBarrier2(&vk.DependencyInfo {
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = (&vk.BufferMemoryBarrier2 {
            .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = self.materials.handle,
            .offset = offset,
            .size = size,
        })[0..1],
    });
}

pub fn recordUpdateSingleVariant(self: *Self, comptime VariantType: type, command_buffer: VulkanContext.CommandBuffer, variant_idx: u32, new_data: VariantType) void {
    const variant_name = inline for (@typeInfo(PolymorphicBSDF).@"union".fields) |union_field| {
        if (union_field.type == VariantType) {
            break union_field.name;
        }
    } else @compileError("Not a material variant: " ++ @typeName(VariantType));

    const offset = @sizeOf(VariantType) * variant_idx;
    const size = @sizeOf(VariantType);
    command_buffer.updateBuffer(@field(self.variant_buffers, variant_name).buffer.handle, offset, size, &new_data);

    command_buffer.pipelineBarrier2(&vk.DependencyInfo {
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = (&vk.BufferMemoryBarrier2 {
            .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = @field(self.variant_buffers, variant_name).buffer.handle,
            .offset = offset,
            .size = size,
        })[0..1],
    });
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.textures.destroy(vc, allocator);
    self.materials.destroy(vc);

    inline for (@typeInfo(VariantBuffers).@"struct".fields) |field| {
        @field(self.variant_buffers, field.name).buffer.destroy(vc);
    }
}

pub const TextureManager = struct {
    const max_descriptors = 8192; // TODO: consider using VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT, reallocation
    // must be kept in sync with shader
    pub const DescriptorLayout = core.descriptor.DescriptorLayout(&.{
        .{
            .descriptor_type = .sampled_image,
            .descriptor_count = max_descriptors,
            .stage_flags = .{ .raygen_bit_khr = true, .compute_bit = true },
            .binding_flags = .{ .partially_bound_bit = true, .update_unused_while_pending_bit = true },
        },
        .{
            .descriptor_type = .sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .raygen_bit_khr = true, .compute_bit = true },
        }
    }, .{}, 1, "Textures");

    data: std.MultiArrayList(Image),
    descriptor_layout: DescriptorLayout,
    descriptor_set: vk.DescriptorSet,
    sampler: vk.Sampler,

    pub fn create(vc: *const VulkanContext) !TextureManager {
        const sampler = try createSampler(vc);
        const descriptor_layout = try DescriptorLayout.create(vc, .{ sampler });

        var descriptor_set: vk.DescriptorSet = undefined;
        try vc.device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo {
            .descriptor_pool = descriptor_layout.pool,
            .descriptor_set_count = 1,
            .p_set_layouts = (&descriptor_layout.handle)[0..1],
        }, (&descriptor_set)[0..1]);
        try vk_helpers.setDebugName(vc.device, descriptor_set, "textures");

        return TextureManager {
            .data = .{},
            .descriptor_layout = descriptor_layout,
            .descriptor_set = descriptor_set,
            .sampler = sampler,
        };
    }

    pub const Handle = u32;

    pub fn upload(self: *TextureManager, vc: *const VulkanContext, comptime T: type, allocator: std.mem.Allocator, encoder: *Encoder, src: core.mem.BufferSlice(T), extent: vk.Extent2D, name: [:0]const u8) !TextureManager.Handle {
        const format = comptime vk_helpers.typeToFormat(T);

        // > If dstImage does not have either a depth/stencil format or a multi-planar format,
        // > then for each element of pRegions, bufferOffset must be a multiple of the texel block size
        // https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/vkCmdCopyBufferToImage.html
        std.debug.assert(src.offset % vk_helpers.texelBlockSize(format) == 0);

        const texture_index: TextureManager.Handle = @intCast(self.data.len);
        std.debug.assert(texture_index < max_descriptors);

        const image = try Image.create(vc, extent, .{ .transfer_dst_bit = true, .sampled_bit = true }, format, false, name);
        try self.data.append(allocator, image);

        encoder.initializeImage(T, src, image.handle, extent);

        vc.device.updateDescriptorSets((&vk.WriteDescriptorSet {
            .dst_set = self.descriptor_set,
            .dst_binding = 0,
            .dst_array_element = texture_index,
            .descriptor_count = 1,
            .descriptor_type = .sampled_image,
            .p_image_info = (&vk.DescriptorImageInfo {
                .image_layout = .general,
                .image_view = image.view,
                .sampler = .null_handle,
            })[0..1],
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        })[0..1], &.{});

        return texture_index;
    }

    pub fn destroy(self: *TextureManager, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
        for (0..self.data.len) |i| {
            const image = self.data.get(i);
            image.destroy(vc);
        }
        self.data.deinit(allocator);
        self.descriptor_layout.destroy(vc);
        vc.device.destroySampler(self.sampler, null);
    }

    pub fn createSampler(vc: *const VulkanContext) !vk.Sampler {
        return try vc.device.createSampler(&.{
            .flags = .{},
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mip_lod_bias = 0.0,
            .anisotropy_enable = .false,
            .max_anisotropy = 0.0,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0.0,
            .max_lod = 0.0,
            .border_color = .float_opaque_white,
            .unnormalized_coordinates = .false,
        }, null);
    }
};
