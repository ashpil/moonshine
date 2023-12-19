const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Commands = core.Commands;
const VkAllocator = core.Allocator;
const vk_helpers = core.vk_helpers;
const ImageManager = core.ImageManager;

const MsneReader = engine.fileformats.msne.MsneReader;

const vector = @import("../vector.zig");
const F32x2 = vector.Vec2(f32);
const F32x3 = vector.Vec3(f32);

// on the host side, materials are represented as a regular tagged union
// 
// since GPUs do not support tagged unions, we solve this with a little indirection,
// translating this into a GPU buffer for each variant, and have a base material struct
// that simply has an enum and a device address, which points to the specific variant
pub const MaterialInfo = struct {
    const normal_components = 2;
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

const Self = @This();

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

pub fn fromMsne(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, msne_reader: MsneReader, inspection: bool) !Self {
    const textures = blk: {
        var manager = ImageManager {};
        errdefer manager.destroy(vc, allocator);
        const texture_count = try msne_reader.readSize();

        for (0..texture_count) |_| {
            const format = try msne_reader.reader.readEnum(vk.Format, .little);
            const extent = try msne_reader.readStruct(vk.Extent2D);
            const size_in_bytes = vk_helpers.imageSizeInBytes(format, extent);
            const bytes = try allocator.alloc(u8, size_in_bytes);
            defer allocator.free(bytes);
            try msne_reader.readSlice(u8, bytes);
            _ = try manager.uploadTexture(vc, vk_allocator, allocator, commands, .{
                .raw = .{
                    .bytes = bytes,
                    .extent = extent,
                    .format = format,
                },
            }, "");
        }
        break :blk manager;
    };

    var variant_buffers = VariantBuffers {};
    inline for (@typeInfo(MaterialVariant).Union.fields) |field| {
        if (@sizeOf(field.type) != 0) {
            const variant_instance_count = try msne_reader.readSize();
            if (variant_instance_count != 0) {
                const host_buffer = try vk_allocator.createHostBuffer(vc, field.type, variant_instance_count, .{ .transfer_src_bit = true });
                defer host_buffer.destroy(vc);

                try msne_reader.readSlice(field.type, host_buffer.data);

                var buffer_flags = vk.BufferUsageFlags{ .shader_device_address_bit = true, .transfer_dst_bit = true };
                if (inspection) buffer_flags = buffer_flags.merge(.{ .transfer_src_bit = true });
                const device_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, field.type, variant_instance_count, buffer_flags);
                errdefer device_buffer.destroy(vc);

                try commands.startRecording(vc);
                commands.recordUploadBuffer(field.type, vc, device_buffer, host_buffer);
                try commands.submitAndIdleUntilDone(vc);

                @field(variant_buffers, field.name) = .{
                    .buffer = device_buffer,
                    .addr = device_buffer.getAddress(vc),
                    .len = host_buffer.data.len,
                };
            }
        }
    }

    const material_count = try msne_reader.readSize();
    const materials_gpu = blk: {
        var materials_host = try vk_allocator.createHostBuffer(vc, Material, material_count, .{ .transfer_src_bit = true });
        defer materials_host.destroy(vc);
        try msne_reader.readSlice(Material, materials_host.data);
        for (materials_host.data) |*material| {
            inline for (@typeInfo(MaterialType).Enum.fields, @typeInfo(MaterialVariant).Union.fields) |enum_field, union_field| {
                if (@as(MaterialType, @enumFromInt(enum_field.value)) == material.type) {
                    material.addr = @field(variant_buffers, enum_field.name).addr + material.addr * @sizeOf(union_field.type);
                }
            }
        }

        var buffer_flags = vk.BufferUsageFlags{ .storage_buffer_bit = true, .transfer_dst_bit = true };
        if (inspection) buffer_flags = buffer_flags.merge(.{ .transfer_src_bit = true });
        const materials_gpu = try vk_allocator.createDeviceBuffer(vc, allocator, Material, material_count, buffer_flags);
        errdefer materials_gpu.destroy(vc);

        try commands.startRecording(vc);
        commands.recordUploadBuffer(Material, vc, materials_gpu, materials_host);
        try commands.submitAndIdleUntilDone(vc);

        break :blk materials_gpu;
    };

    return Self {
        .textures = textures,
        .material_count = material_count,
        .materials = materials_gpu,
        .variant_buffers = variant_buffers,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.textures.destroy(vc, allocator);
    self.materials.destroy(vc);

    inline for (@typeInfo(VariantBuffers).Struct.fields) |field| {
        @field(self.variant_buffers, field.name).buffer.destroy(vc);
    }
}
