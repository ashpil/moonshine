const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const ImageManager = @import("./ImageManager.zig");

const vector = @import("../vector.zig");

pub const StandardPBR = extern struct {
    normal: u32,
    emissive: u32,
    color: u32,
    metalness: u32,
    roughness: u32,
    ior: f32 = 1.5,
};

textures: ImageManager,
materials: VkAllocator.DeviceBuffer, // StandardPBR

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, texture_sources: []const ImageManager.TextureSource, materials: []const StandardPBR) !Self {
    var textures = try ImageManager.createTexture(vc, vk_allocator, allocator, texture_sources, commands);
    errdefer textures.destroy(vc, allocator);

    const materials_tmp = try vk_allocator.createHostBuffer(vc, StandardPBR, @intCast(u32, materials.len), .{ .transfer_src_bit = true });
    defer materials_tmp.destroy(vc);
    std.mem.copy(StandardPBR, materials_tmp.data, materials);

    const materials_gpu = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(StandardPBR) * materials.len, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
    errdefer materials_gpu.destroy(vc);
    
    try commands.startRecording(vc);
    commands.recordUploadBuffer(StandardPBR, vc, materials_gpu, materials_tmp);
    try commands.submitAndIdleUntilDone(vc);

    return Self {
        .textures = textures,
        .materials = materials_gpu,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.textures.destroy(vc, allocator);
    self.materials.destroy(vc);
}
