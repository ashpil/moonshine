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

pub const Material = extern struct {
    const normal_components = 2;
    const emissive_components = 3;
    // all materials have normal and emissive
    normal: u32,
    emissive: u32,

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

pub const AnyMaterial = union(MaterialType) {
    glass: Glass,
    lambert: Lambert,
    perfect_mirror: void, // no payload
    standard_pbr: StandardPBR,
};

pub const StandardPBR = extern struct {
    const color_components = 3;
    const metalness_components = 1;
    const roughness_components = 1;

    color: u32,
    metalness: u32,
    roughness: u32,
    ior: f32 = 1.5,
};

pub const Lambert = extern struct {
    const color_components = 3;
    color: u32,
};

pub const Glass = extern struct {
    ior: f32,
};

const VariantBuffers = blk: {
    const variants = @typeInfo(AnyMaterial).Union.fields;
    comptime var buffer_count = 0;
    inline for (variants) |variant| {
        if (variant.type != void) {
            buffer_count += 1;
        }
    }
    comptime var fields: [buffer_count]std.builtin.Type.StructField = undefined;
    comptime var current_field = 0;
    inline for (variants) |variant| {
        if (variant.type != void) {
            fields[current_field] = .{
                .name = variant.name,
                .type = VkAllocator.DeviceBuffer(variant.type),
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(VkAllocator.DeviceBuffer(variant.type)),
            };
            current_field += 1;
        }
    }
    break :blk @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
};

const Addrs = blk: {
    const variants = @typeInfo(AnyMaterial).Union.fields;
    comptime var fields: [variants.len]std.builtin.Type.StructField = undefined;
    inline for (&fields, variants) |*field, variant| {
        field.* = .{
            .name = variant.name,
            .type = vk.DeviceAddress,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(vk.DeviceAddress),
        };
    }
    break :blk @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
};

material_count: u32,
textures: ImageManager,
materials: VkAllocator.DeviceBuffer(Material),
addrs: Addrs,

variant_buffers: VariantBuffers,

const Self = @This();

// inspection bool specifies whether some buffers should be created with the `transfer_src_flag` for inspection
pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, texture_sources: []const ImageManager.TextureSource, materials: MaterialList, inspection: bool) !Self {

    var variant_buffers: VariantBuffers = undefined;
    var addrs: Addrs = undefined;
    inline for (@typeInfo(AnyMaterial).Union.fields) |field| {
        if (@sizeOf(field.type) != 0) {
            if (@field(materials.variants, field.name).items.len != 0) {
                const data = @field(materials.variants, field.name).items;
                const host_buffer = try vk_allocator.createHostBuffer(vc, field.type, @intCast(data.len), .{ .transfer_src_bit = true });
                defer host_buffer.destroy(vc);

                var buffer_flags = vk.BufferUsageFlags { .shader_device_address_bit = true, .transfer_dst_bit = true };
                if (inspection) buffer_flags = buffer_flags.merge(.{ .transfer_src_bit = true });
                const device_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, field.type, @intCast(data.len), buffer_flags);
                errdefer device_buffer.destroy(vc);

                std.mem.copy(field.type, host_buffer.data, data);
                try commands.startRecording(vc);
                commands.recordUploadBuffer(field.type, vc, device_buffer, host_buffer);
                try commands.submitAndIdleUntilDone(vc);

                @field(variant_buffers, field.name) = device_buffer;
                @field(addrs, field.name) = device_buffer.getAddress(vc);
            } else {
                @field(variant_buffers, field.name) = .{ .handle = .null_handle };
                @field(addrs, field.name) = 0;
            }
        } else {
            @field(addrs, field.name) = 0;
        }
    }

    const material_count: u32 = @intCast(materials.materials.items.len);
    const materials_gpu = blk: {
        var materials_host = try vk_allocator.createHostBuffer(vc, Material, material_count, .{ .transfer_src_bit = true });
        defer materials_host.destroy(vc);
        for (materials.materials.items, materials_host.data) |material, *data| {
            data.* = material;
            inline for (@typeInfo(MaterialType).Enum.fields, @typeInfo(AnyMaterial).Union.fields) |enum_field, union_field| {
                if (@as(MaterialType, @enumFromInt(enum_field.value)) == material.type) {
                    data.addr = @field(addrs, enum_field.name) + material.addr * @sizeOf(union_field.type);
                }
            }
        }

        var buffer_flags = vk.BufferUsageFlags { .storage_buffer_bit = true, .transfer_dst_bit = true };
        if (inspection) buffer_flags = buffer_flags.merge(.{ .transfer_src_bit = true });
        const materials_gpu = try vk_allocator.createDeviceBuffer(vc, allocator, Material, material_count, buffer_flags);
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
        try textures.uploadTexture(vc, vk_allocator, allocator, commands, source, "");
    }

    return Self {
        .textures = textures,
        .material_count = material_count,
        .materials = materials_gpu,
        .variant_buffers = variant_buffers,
        .addrs = addrs,
    };
}

pub fn recordUpdateSingleVariant(self: *Self, vc: *const VulkanContext, comptime VariantType: type, command_buffer: vk.CommandBuffer, variant_idx: u32, new_data: VariantType) void {
    const variant_name = inline for (@typeInfo(AnyMaterial).Union.fields) |union_field| {
        if (union_field.type == VariantType) {
            break union_field.name;
        }
    } else @compileError("Not a material variant: " ++ @typeName(VariantType));

    const offset = @sizeOf(VariantType) * variant_idx;
    const size = @sizeOf(VariantType);
    vc.device.cmdUpdateBuffer(command_buffer, @field(self.variant_buffers, variant_name).handle, offset, size, &new_data);

    vc.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = @ptrCast(&vk.BufferMemoryBarrier2 {
            .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = @field(self.variant_buffers, variant_name).handle,
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
            const format = try msne_reader.reader.readEnum(vk.Format, .Little);
            const extent = try msne_reader.readStruct(vk.Extent2D);
            const size_in_bytes = vk_helpers.imageSizeInBytes(format, extent);
            const bytes = try allocator.alloc(u8, size_in_bytes);
            defer allocator.free(bytes);
            try msne_reader.readSlice(u8, bytes);
            try manager.uploadTexture(vc, vk_allocator, allocator, commands, .{
                .raw = .{
                    .bytes = bytes,
                    .extent = extent,
                    .format = format,
                },
            }, "");
        }
        break :blk manager;
    };

    var variant_buffers: VariantBuffers = undefined;
    var addrs: Addrs = undefined;
    inline for (@typeInfo(AnyMaterial).Union.fields) |field| {
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

                @field(variant_buffers, field.name) = device_buffer;
                @field(addrs, field.name) = device_buffer.getAddress(vc);
            } else {
                @field(variant_buffers, field.name) = .{ .handle = .null_handle };
                @field(addrs, field.name) = 0;
            }
        } else {
            @field(addrs, field.name) = 0;
        }
    }

    const material_count = try msne_reader.readSize();
    const materials_gpu = blk: {
        var materials_host = try vk_allocator.createHostBuffer(vc, Material, material_count, .{ .transfer_src_bit = true });
        defer materials_host.destroy(vc);
        try msne_reader.readSlice(Material, materials_host.data);
        for (materials_host.data) |*material| {
            inline for (@typeInfo(MaterialType).Enum.fields, @typeInfo(AnyMaterial).Union.fields) |enum_field, union_field| {
                if (@as(MaterialType, @enumFromInt(enum_field.value)) == material.type) {
                    material.addr = @field(addrs, enum_field.name) + material.addr * @sizeOf(union_field.type);
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
        .addrs = addrs,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.textures.destroy(vc, allocator);
    self.materials.destroy(vc);

    inline for (@typeInfo(VariantBuffers).Struct.fields) |field| {
        @field(self.variant_buffers, field.name).destroy(vc);
    }
}

pub const MaterialList = struct {
    const VariantLists = blk: {
        const variants = @typeInfo(AnyMaterial).Union.fields;
        comptime var buffer_count = 0;
        inline for (variants) |variant| {
            if (variant.type != void) {
                buffer_count += 1;
            }
        }
        comptime var fields: [buffer_count]std.builtin.Type.StructField = undefined;
        comptime var current_field = 0;
        inline for (variants) |variant| {
            if (variant.type != void) {
                fields[current_field] = .{
                    .name = variant.name,
                    .type = std.ArrayListUnmanaged(variant.type),
                    .default_value = &std.ArrayListUnmanaged(variant.type) {},
                    .is_comptime = false,
                    .alignment = @alignOf(std.ArrayListUnmanaged(variant.type)),
                };
                current_field += 1;
            }
        }
        break :blk @Type(.{
            .Struct = .{
                .layout = .Auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    };

    materials: std.ArrayListUnmanaged(Material) = .{},

    variants: VariantLists = .{},

    pub fn append(self: *MaterialList, allocator: std.mem.Allocator, material: Material, any_material: AnyMaterial) !void {
        var mat_local = material;
        inline for (@typeInfo(MaterialType).Enum.fields, @typeInfo(AnyMaterial).Union.fields) |enum_field, union_field| {
            if (@as(MaterialType, @enumFromInt(enum_field.value)) == any_material) {
                mat_local.type = @enumFromInt(enum_field.value);
                if (union_field.type != void) {
                    mat_local.addr = @field(self.variants, enum_field.name).items.len;
                    try @field(self.variants, enum_field.name).append(allocator, @field(any_material, enum_field.name));
                }
            }
        }
        try self.materials.append(allocator, mat_local);
    }

    pub fn destroy(self: *MaterialList, allocator: std.mem.Allocator) void {
        self.materials.deinit(allocator);

        inline for (@typeInfo(VariantLists).Struct.fields) |field| {
            @field(self.variants, field.name).deinit(allocator);
        }
    }
};
