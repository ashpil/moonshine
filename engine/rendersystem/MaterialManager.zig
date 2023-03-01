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

pub const AnyMaterial = union(MaterialType) {
    standard_pbr: StandardPBR,
    lambert: Lambert,
    perfect_mirror: void, // no payload
};

textures: ImageManager,
materials: VkAllocator.DeviceBuffer, // Material

standard_pbr: VkAllocator.DeviceBuffer, // StandardPBR
lambert: VkAllocator.DeviceBuffer, // Lambert

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, texture_sources: []const ImageManager.TextureSource, materials: MaterialList) !Self {
    const standard_pbr = blk: {
        const standard_pbr = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(StandardPBR) * materials.standard_pbrs.items.len, .{ .shader_device_address_bit = true, .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer standard_pbr.destroy(vc);

        try commands.uploadData(vc, vk_allocator, standard_pbr.handle, std.mem.sliceAsBytes(materials.standard_pbrs.items));
        
        break :blk standard_pbr;
    };

    const spbr_addr = standard_pbr.getAddress(vc);

    const lambert = blk: {
        const lambert = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(Lambert) * materials.lamberts.items.len, .{ .shader_device_address_bit = true, .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer lambert.destroy(vc);

        try commands.uploadData(vc, vk_allocator, lambert.handle, std.mem.sliceAsBytes(materials.lamberts.items));
        
        break :blk lambert;
    };

    const lambert_addr = lambert.getAddress(vc);

    const materials_gpu = blk: {
        const materials_tmp = try vk_allocator.createHostBuffer(vc, Material, @intCast(u32, materials.materials.items.len), .{ .transfer_src_bit = true });
        defer materials_tmp.destroy(vc);
        for (materials.materials.items) |material, i| {
            materials_tmp.data[i] = material;
            materials_tmp.data[i].addr = switch (material.type) {
                .standard_pbr => spbr_addr + material.addr * @sizeOf(StandardPBR),
                .lambert => lambert_addr + material.addr * @sizeOf(Lambert),
                .perfect_mirror => 0,
            };
        }

        const materials_gpu = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(Material) * materials.materials.items.len, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer materials_gpu.destroy(vc);
        
        try commands.startRecording(vc);
        commands.recordUploadBuffer(Material, vc, materials_gpu, materials_tmp);
        try commands.submitAndIdleUntilDone(vc);

        break :blk materials_gpu;
    };

    var textures = try ImageManager.createTexture(vc, vk_allocator, allocator, texture_sources, commands);
    errdefer textures.destroy(vc, allocator);

    return Self {
        .textures = textures,
        .materials = materials_gpu,
        .standard_pbr = standard_pbr,
        .lambert = lambert,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.textures.destroy(vc, allocator);
    self.materials.destroy(vc);
    self.standard_pbr.destroy(vc);
    self.lambert.destroy(vc);
}

pub const MaterialList = struct {
    materials: std.ArrayListUnmanaged(Material) = .{},

    standard_pbrs: std.ArrayListUnmanaged(StandardPBR) = .{},
    lamberts: std.ArrayListUnmanaged(Lambert) = .{},

    pub fn append(self: *MaterialList, allocator: std.mem.Allocator, material: Material, any_material: AnyMaterial) !void {
        var mat_local = material;
        switch (any_material) {
            .standard_pbr => {
                try self.standard_pbrs.append(allocator, any_material.standard_pbr);
                mat_local.addr = self.standard_pbrs.items.len - 1;
                mat_local.type = .standard_pbr;
            },
            .lambert => {
                try self.lamberts.append(allocator, any_material.lambert);
                mat_local.addr = self.lamberts.items.len - 1;
                mat_local.type = .lambert;
            },
            .perfect_mirror => {
                mat_local.addr = 0;
                mat_local.type = .perfect_mirror;
            },
        }
        try self.materials.append(allocator, mat_local);
    }

    pub fn destroy(self: *MaterialList, allocator: std.mem.Allocator) void {
        self.materials.deinit(allocator);

        self.standard_pbrs.deinit(allocator);
        self.lamberts.deinit(allocator);
    }
};
