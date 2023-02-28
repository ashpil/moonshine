const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const ImageManager = @import("./ImageManager.zig");

const vector = @import("../vector.zig");

pub const MaterialType = enum(c_int) {
    standard_pbr,
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

textures: ImageManager,
materials: VkAllocator.DeviceBuffer, // Material

standard_pbr: VkAllocator.DeviceBuffer, // StandardPBR

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, texture_sources: []const ImageManager.TextureSource, materials: []const Material, standard_pbr: []const StandardPBR) !Self {
    const standard_pbr_gpu = blk: {
        const standard_pbr_gpu = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(StandardPBR) * standard_pbr.len, .{ .shader_device_address_bit = true, .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer standard_pbr_gpu.destroy(vc);

        try commands.uploadData(vc, vk_allocator, standard_pbr_gpu.handle, std.mem.sliceAsBytes(standard_pbr));
        
        break :blk standard_pbr_gpu;
    };

    const spbr_addr = standard_pbr_gpu.getAddress(vc);

    const materials_gpu = blk: {
        const materials_tmp = try vk_allocator.createHostBuffer(vc, Material, @intCast(u32, materials.len), .{ .transfer_src_bit = true });
        defer materials_tmp.destroy(vc);
        for (materials) |material, i| {
            materials_tmp.data[i] = material;
            materials_tmp.data[i].addr = spbr_addr + material.addr * @sizeOf(StandardPBR);
        }

        const materials_gpu = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(Material) * materials.len, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
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
        .standard_pbr = standard_pbr_gpu,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.textures.destroy(vc, allocator);
    self.materials.destroy(vc);
    self.standard_pbr.destroy(vc);
}
