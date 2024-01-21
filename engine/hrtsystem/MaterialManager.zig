const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Commands = core.Commands;
const VkAllocator = core.Allocator;
const vk_helpers = core.vk_helpers;
const ImageManager = core.ImageManager;

const vector = @import("../vector.zig");
const F32x2 = vector.Vec2(f32);
const F32x3 = vector.Vec3(f32);

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
    normal: ImageManager.Handle,
    emissive: ImageManager.Handle,

    // then material-specific data
    variant: MaterialVariant,
};

pub const Material = extern struct {
    // all materials have normal and emissive
    normal: ImageManager.Handle,
    emissive: ImageManager.Handle,

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

    color: ImageManager.Handle,
    metalness: ImageManager.Handle,
    roughness: ImageManager.Handle,
    ior: f32 = 1.5,
};

pub const Lambert = extern struct {
    const color_components = 3;
    color: ImageManager.Handle,
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

material_count: u32 = 0,
textures: ImageManager = .{},
materials: VkAllocator.DeviceBuffer(Material) = .{},

variant_buffers: VariantBuffers = .{},

const Handle = u32;

const Self = @This();

const max_materials = 512; // TODO: resizable buffers

// you can either do this or create below, but not both
// texture handles must've been already added to the MaterialManager's textures
pub fn uploadMaterial(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, info: MaterialInfo) !Handle {
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

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, texture_sources: []const ImageManager.TextureSource, materials: []const MaterialInfo) !Self {
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

    var textures = ImageManager {};
    errdefer textures.destroy(vc, allocator);
    for (texture_sources) |source| {
        _ = try textures.uploadTexture(vc, vk_allocator, allocator, commands, source, "");
    }

    return Self {
        .textures = textures,
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
