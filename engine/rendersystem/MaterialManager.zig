const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const ImageManager = @import("./ImageManager.zig");

const vector = @import("../vector.zig");

pub const MaterialType = enum(c_int) {
    standard_pbr,
    lambert,
    perfect_mirror,
    glass,
};

pub const Material = extern struct {
    // all materials have normal and emissive
    normal: u32,
    emissive: u32,

    // then each material has specific type which influences what buffer addr looks into
    type: MaterialType = .standard_pbr,
    addr: vk.DeviceAddress,
};

pub const StandardPBR = extern struct {
    color: u32,
    metalness: u32,
    roughness: u32,
    ior: f32 = 1.5,
};

pub const Lambert = extern struct {
    color: u32,
};

pub const Glass = extern struct {
    ior: f32,
};

pub const AnyMaterial = union(MaterialType) {
    standard_pbr: StandardPBR,
    lambert: Lambert,
    perfect_mirror: void, // no payload
    glass: Glass,
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
                .type = VkAllocator.DeviceBuffer,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(VkAllocator.DeviceBuffer),
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

const VariantBuffersHost = blk: {
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
                .type = VkAllocator.HostBuffer(variant.type),
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(VkAllocator.DeviceBuffer),
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

textures: ImageManager,
materials: VkAllocator.DeviceBuffer, // Material
materials_host: VkAllocator.HostBuffer(Material),

variant_buffers: VariantBuffers,
variant_buffers_host: VariantBuffersHost,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, texture_sources: []const ImageManager.TextureSource, materials: MaterialList) !Self {
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

    var variant_buffers: VariantBuffers = undefined;
    var variant_buffers_host: VariantBuffersHost = undefined;
    var addrs: Addrs = undefined;
    inline for (@typeInfo(AnyMaterial).Union.fields) |field| {
        if (@sizeOf(field.type) != 0) {
            if (@field(materials.variants, field.name).items.len != 0) {
                const data = @field(materials.variants, field.name).items;
                const host_buffer = try vk_allocator.createHostBuffer(vc, field.type, @intCast(u32, data.len), .{ .transfer_src_bit = true });
                errdefer host_buffer.destroy(vc);
                const device_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(field.type) * data.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
                errdefer device_buffer.destroy(vc);

                std.mem.copy(field.type, host_buffer.data, data);
                try commands.startRecording(vc);
                commands.recordUploadBuffer(field.type, vc, device_buffer, host_buffer);
                try commands.submitAndIdleUntilDone(vc);
                
                @field(variant_buffers, field.name) = device_buffer;
                @field(variant_buffers_host, field.name) = host_buffer;
                @field(addrs, field.name) = device_buffer.getAddress(vc);
            } else {
                @field(variant_buffers, field.name) = VkAllocator.DeviceBuffer { .handle = .null_handle };
                @field(variant_buffers_host, field.name) = VkAllocator.HostBuffer(field.type) { .handle = .null_handle, .memory = .null_handle, .data = &.{} };
                @field(addrs, field.name) = 0;
            }
        } else {
            @field(addrs, field.name) = 0;
        }
    }

    var materials_gpu: VkAllocator.DeviceBuffer = undefined;
    var materials_host: VkAllocator.HostBuffer(Material) = undefined;
    {
        materials_host = try vk_allocator.createHostBuffer(vc, Material, @intCast(u32, materials.materials.items.len), .{ .transfer_src_bit = true });
        errdefer materials_host.destroy(vc);
        for (materials.materials.items, materials_host.data) |material, *data| {
            data.* = material;
            inline for (@typeInfo(MaterialType).Enum.fields, @typeInfo(AnyMaterial).Union.fields) |enum_field, union_field| {
                if (@intToEnum(MaterialType, enum_field.value) == material.type) {
                    data.addr = @field(addrs, enum_field.name) + material.addr * @sizeOf(union_field.type);
                }
            }
        }

        materials_gpu = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(Material) * materials.materials.items.len, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer materials_gpu.destroy(vc);
        
        try commands.startRecording(vc);
        commands.recordUploadBuffer(Material, vc, materials_gpu, materials_host);
        try commands.submitAndIdleUntilDone(vc);
    }

    var textures = try ImageManager.createTexture(vc, vk_allocator, allocator, texture_sources, commands);
    errdefer textures.destroy(vc, allocator);

    return Self {
        .textures = textures,
        .materials = materials_gpu,
        .materials_host = materials_host,
        .variant_buffers = variant_buffers,
        .variant_buffers_host = variant_buffers_host,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.textures.destroy(vc, allocator);
    self.materials.destroy(vc);
    self.materials_host.destroy(vc);

    inline for (@typeInfo(VariantBuffers).Struct.fields) |field| {
        @field(self.variant_buffers, field.name).destroy(vc);
    }

    inline for (@typeInfo(VariantBuffersHost).Struct.fields) |field| {
        @field(self.variant_buffers_host, field.name).destroy(vc);
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
            if (@intToEnum(MaterialType, enum_field.value) == any_material) {
                mat_local.type = @intToEnum(MaterialType, enum_field.value);
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
