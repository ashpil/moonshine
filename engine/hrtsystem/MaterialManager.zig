const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Commands = core.Commands;
const VkAllocator = core.Allocator;
const Image = core.Image;
const vk_helpers = core.vk_helpers;

const F32x2 = engine.vector.Vec2(f32);
const F32x3 = engine.vector.Vec3(f32);
const F32x4 = engine.vector.Vec4(f32);

// on the host side, materials are represented as a regular tagged union
//
// since GPUs do not support tagged unions, we solve this with a little indirection,
// translating this into a GPU buffer for each variant, and have a base material struct
// that simply has an enum and a device address, which points to the specific variant
pub const MaterialInfo = struct {
    pub const default_normal = F32x2.new(0.5, 0.5);
    const normal_components = @TypeOf(default_normal).element_count;
    const emissive_components = 3;

    // all materials have normal and emissive
    normal: TextureManager.Handle,
    emissive: TextureManager.Handle,

    // then material-specific data
    variant: MaterialVariant,
};

pub const Material = extern struct {
    // all materials have normal and emissive
    normal: TextureManager.Handle,
    emissive: TextureManager.Handle,

    // then each material has specific type which influences what buffer addr looks into
    type: MaterialType = .standard_pbr,
    addr: vk.DeviceAddress,
};

pub const MaterialType = enum(u32) {
    glass,
    lambert,
    perfect_mirror,
    standard_pbr,
};

pub const MaterialVariant = union(MaterialType) {
    glass: Glass,
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
    ior: f32 = 1.5,
};

pub const Lambert = extern struct {
    const color_components = 3;
    color: TextureManager.Handle,
};

pub const Glass = extern struct {
    ior: f32,
};

// takes in a tagged union and returns a struct that has each of the union fields as a field,
// with type InnerFn(field)
//
// sometimes I have a little too much fun with metaprogramming
fn StructFromTaggedUnion(comptime Union: type, comptime InnerFn: fn(type) type) type {
    if (@typeInfo(Union) != .Union) @compileError(@typeName(Union) ++ " must be a union, but is not");
    const variants = @typeInfo(Union).Union.fields;
    comptime var fields: [variants.len]std.builtin.Type.StructField = undefined;
    for (&fields, variants) |*field, variant| {
        const T = InnerFn(variant.type);
        field.* = .{
            .name = variant.name,
            .type = T,
            .default_value = &T {},
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn VariantBuffer(comptime T: type) type {
    return struct {
        buffer: VkAllocator.DeviceBuffer(T) = .{},
        addr: vk.DeviceAddress = 0,
        len: vk.DeviceSize = 0,
    };
}

const VariantBuffers = StructFromTaggedUnion(MaterialVariant, VariantBuffer);

material_count: u32,
textures: TextureManager,
materials: VkAllocator.DeviceBuffer(Material),

variant_buffers: VariantBuffers,

const Handle = u32;

const Self = @This();

const max_materials = 512; // TODO: resizable buffers

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
pub fn upload(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, info: MaterialInfo) !Handle {
    std.debug.assert(self.material_count < max_materials);

    try commands.startRecording(vc);
    inline for (@typeInfo(MaterialVariant).Union.fields, 0..) |field, field_idx| {
        if (@as(MaterialType, @enumFromInt(field_idx)) == std.meta.activeTag(info.variant)) {
            if (@sizeOf(field.type) != 0) {
                const variant_buffer = &@field(self.variant_buffers, field.name);
                if (variant_buffer.buffer.is_null()) {
                    variant_buffer.buffer = try vk_allocator.createDeviceBuffer(vc, allocator, field.type, max_materials, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
                    variant_buffer.addr = variant_buffer.buffer.getAddress(vc);
                }
                commands.recordUpdateBuffer(field.type, vc, variant_buffer.buffer, &.{ @field(info.variant, field.name) }, variant_buffer.len);
                variant_buffer.len += 1;
            }

            const gpu_material = Material {
                .normal = info.normal,
                .emissive = info.emissive,
                .type = std.meta.activeTag(info.variant),
                .addr = @field(self.variant_buffers, field.name).addr + (@field(self.variant_buffers, field.name).len - 1) * @sizeOf(field.type),
            };
            if (self.materials.is_null()) self.materials = try vk_allocator.createDeviceBuffer(vc, allocator, Material, max_materials, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
            commands.recordUpdateBuffer(Material, vc, self.materials, &.{ gpu_material }, self.material_count);
        }
    }
    try commands.submitAndIdleUntilDone(vc);

    self.material_count += 1;
    return self.material_count - 1;
}

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, materials: []const MaterialInfo) !Self {
    var variant_lists = StructFromTaggedUnion(MaterialVariant, std.ArrayListUnmanaged) {};
    defer inline for (@typeInfo(MaterialVariant).Union.fields) |field| {
        @field(variant_lists, field.name).deinit(allocator);
    };
    const variant_indices = try allocator.alloc(vk.DeviceAddress, materials.len);
    defer allocator.free(variant_indices);
    for (materials, variant_indices) |material_info, *variant_index| {
        inline for (@typeInfo(MaterialVariant).Union.fields, 0..) |field, field_idx| {
            if (@as(MaterialType, @enumFromInt(field_idx)) == std.meta.activeTag(material_info.variant)) {
                variant_index.* = @field(variant_lists, field.name).items.len;
                try @field(variant_lists, field.name).append(allocator, @field(material_info.variant, field.name));
            }
        }
    }

    var variant_buffers = VariantBuffers {};
    inline for (@typeInfo(MaterialVariant).Union.fields) |field| {
        if (@sizeOf(field.type) != 0) {
            if (@field(variant_lists, field.name).items.len != 0) {
                const data = @field(variant_lists, field.name).items;
                const host_buffer = try vk_allocator.createHostBuffer(vc, field.type, @intCast(data.len), .{ .transfer_src_bit = true });
                defer host_buffer.destroy(vc);

                const device_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, field.type, @intCast(data.len), .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
                errdefer device_buffer.destroy(vc);

                @memcpy(host_buffer.data, data);
                try commands.startRecording(vc);
                commands.recordUploadBuffer(field.type, vc, device_buffer, host_buffer);
                try commands.submitAndIdleUntilDone(vc);

                @field(variant_buffers, field.name) = .{
                    .buffer = device_buffer,
                    .addr = device_buffer.getAddress(vc),
                    .len = data.len,
                };
            }
        }
    }

    const material_count: u32 = @intCast(materials.len);
    const materials_gpu = blk: {
        var materials_host = try vk_allocator.createHostBuffer(vc, Material, material_count, .{ .transfer_src_bit = true });
        defer materials_host.destroy(vc);
        for (materials_host.data, materials, variant_indices) |*data, material, variant_index| {
            data.normal = material.normal;
            data.emissive = material.emissive;
            data.type = std.meta.activeTag(material.variant);
            inline for (@typeInfo(MaterialVariant).Union.fields, 0..) |union_field, field_idx| {
                if (@as(MaterialType, @enumFromInt(field_idx)) == data.type) {
                    data.addr = @field(variant_buffers, union_field.name).addr + variant_index * @sizeOf(union_field.type);
                }
            }
        }
        const materials_gpu = try vk_allocator.createDeviceBuffer(vc, allocator, Material, material_count, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer materials_gpu.destroy(vc);

        if (material_count != 0)
        {
            try commands.startRecording(vc);
            commands.recordUploadBuffer(Material, vc, materials_gpu, materials_host);
            try commands.submitAndIdleUntilDone(vc);
        }

        break :blk materials_gpu;
    };

    return Self {
        .textures = try TextureManager.create(vc),
        .material_count = material_count,
        .materials = materials_gpu,
        .variant_buffers = variant_buffers,
    };
}

pub fn recordUpdateSingleVariant(self: *Self, vc: *const VulkanContext, comptime VariantType: type, command_buffer: vk.CommandBuffer, variant_idx: u32, new_data: VariantType) void {
    const variant_name = inline for (@typeInfo(MaterialVariant).Union.fields) |union_field| {
        if (union_field.type == VariantType) {
            break union_field.name;
        }
    } else @compileError("Not a material variant: " ++ @typeName(VariantType));

    const offset = @sizeOf(VariantType) * variant_idx;
    const size = @sizeOf(VariantType);
    vc.device.cmdUpdateBuffer(command_buffer, @field(self.variant_buffers, variant_name).buffer.handle, offset, size, &new_data);

    vc.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = @ptrCast(&vk.BufferMemoryBarrier2 {
            .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = @field(self.variant_buffers, variant_name).buffer.handle,
            .offset = offset,
            .size = size,
        }),
    });
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.textures.destroy(vc, allocator);
    self.materials.destroy(vc);

    inline for (@typeInfo(VariantBuffers).Struct.fields) |field| {
        @field(self.variant_buffers, field.name).buffer.destroy(vc);
    }
}

// TODO: individual texture destruction
pub const TextureManager = struct {
    const max_descriptors = 1024; // TODO: consider using VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT, reallocation
    // must be kept in sync with shader
    pub const DescriptorLayout = core.descriptor.DescriptorLayout(&.{
        .{
            .descriptor_type = .sampled_image,
            .descriptor_count = max_descriptors,
            .stage_flags = .{ .raygen_bit_khr = true },
            .binding_flags = .{ .partially_bound_bit = true, .update_unused_while_pending_bit = true },
        }
    }, .{}, 1, "Textures");

    pub const Source = union(enum) {
        pub const Raw = struct {
            bytes: []const u8,
            extent: vk.Extent2D,
            format: vk.Format,
        };

        raw: Raw,
        f32x3: F32x3,
        f32x2: F32x2,
        f32x1: f32,
    };

    comptime {
        // so that we can do some hacky stuff below like
        // reinterpret the f32x3 field as F32x4
        // TODO: even this is not quite right
        std.debug.assert(@sizeOf(Source) >= @sizeOf(F32x4));
    }

    data: std.MultiArrayList(Image),
    descriptor_layout: DescriptorLayout,
    descriptor_set: vk.DescriptorSet,

    pub fn create(vc: *const VulkanContext) !TextureManager {
        const descriptor_layout = try DescriptorLayout.create(vc);

        var descriptor_set: vk.DescriptorSet = undefined;
        try vc.device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo {
            .descriptor_pool = descriptor_layout.pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_layout.handle),
        }, @ptrCast(&descriptor_set));
        try vk_helpers.setDebugName(vc, descriptor_set, "textures");
        
        return TextureManager {
            .data = .{},
            .descriptor_layout = descriptor_layout,
            .descriptor_set = descriptor_set,
        };
    }

    pub const Handle = u32;

    pub fn upload(self: *TextureManager, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, source: Source, name: [:0]const u8) !TextureManager.Handle {
        const texture_index: TextureManager.Handle = @intCast(self.data.len);
        std.debug.assert(texture_index < max_descriptors);

        var extent: vk.Extent2D = undefined;
        var bytes: []const u8 = undefined;
        var format: vk.Format = undefined;
        switch (source) {
            .raw => |raw_info| {
                bytes = raw_info.bytes;
                extent = raw_info.extent;
                format = raw_info.format;
            },
            .f32x3 => {
                bytes = std.mem.asBytes(&source.f32x3);
                bytes.len = @sizeOf(F32x4); // we store this as f32x4
                extent = vk.Extent2D {
                    .width = 1,
                    .height = 1,
                };
                format = .r32g32b32a32_sfloat;
            },
            .f32x2 => {
                bytes = std.mem.asBytes(&source.f32x2);
                extent = vk.Extent2D {
                    .width = 1,
                    .height = 1,
                };
                format = .r32g32_sfloat;
            },
            .f32x1 => {
                bytes = std.mem.asBytes(&source.f32x1);
                extent = vk.Extent2D {
                    .width = 1,
                    .height = 1,
                };
                format = .r32_sfloat;
            },
        }
        const image = try Image.create(vc, vk_allocator, extent, .{ .transfer_dst_bit = true, .sampled_bit = true }, format, name);
        try self.data.append(allocator, image);

        try commands.uploadDataToImage(vc, vk_allocator, image.handle, bytes, extent, .shader_read_only_optimal);

        vc.device.updateDescriptorSets(1, @ptrCast(&.{
            vk.WriteDescriptorSet {
                .dst_set = self.descriptor_set,
                .dst_binding = 0,
                .dst_array_element = texture_index,
                .descriptor_count = 1,
                .descriptor_type = .sampled_image,
                .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                    .image_layout = .shader_read_only_optimal,
                    .image_view = image.view,
                    .sampler = .null_handle,
                }),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
        }), 0, null);

        return texture_index;
    }

    pub fn destroy(self: *TextureManager, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
        for (0..self.data.len) |i| {
            const image = self.data.get(i);
            image.destroy(vc);
        }
        self.data.deinit(allocator);
        self.descriptor_layout.destroy(vc);
    }

    pub fn createSampler(vc: *const VulkanContext) !vk.Sampler {
        return try vc.device.createSampler(&.{
            .flags = .{},
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mip_lod_bias = 0.0,
            .anisotropy_enable = vk.FALSE,
            .max_anisotropy = 0.0,
            .compare_enable = vk.FALSE,
            .compare_op = .always,
            .min_lod = 0.0,
            .max_lod = 0.0,
            .border_color = .float_opaque_white,
            .unnormalized_coordinates = vk.FALSE,
        }, null);
    }
};
