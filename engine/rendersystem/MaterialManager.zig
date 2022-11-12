const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const ImageManager = @import("./ImageManager.zig");

pub const Material = struct {
    color: ImageManager.TextureSource,
    roughness: ImageManager.TextureSource,
    normal: ImageManager.TextureSource,
    
    values: Values,
};

// `value` is the term I use for non-texture material input
pub const Values = packed struct {
    metalness: f32 = 0.0,
    ior: f32 = 1.5,
};

textures: ImageManager, // (color, roughness, normal) * N
values: VkAllocator.DeviceBuffer, // holds Values for each material

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, materials: []const Material) !Self {
    const texture_sources = try allocator.alloc(ImageManager.TextureSource, materials.len * 3);
    defer allocator.free(texture_sources);

    const values_tmp = try vk_allocator.createHostBuffer(vc, Values, @intCast(u32, materials.len), .{ .transfer_src_bit = true });
    defer values_tmp.destroy(vc);

    for (materials) |set, i| {
        texture_sources[3 * i + 0] = set.color;
        texture_sources[3 * i + 1] = set.roughness;
        texture_sources[3 * i + 2] = set.normal;

        values_tmp.data[i] = set.values;
    }

    const values = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(Values) * materials.len, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
    errdefer values.destroy(vc);

    try commands.startRecording(vc);
    commands.recordUploadBuffer(Values, vc, values, values_tmp);
    try commands.submitAndIdleUntilDone(vc);

    var textures = try ImageManager.createTexture(vc, vk_allocator, allocator, texture_sources, commands);
    errdefer textures.destroy(vc, allocator);

    return Self {
        .textures = textures,
        .values = values,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.textures.destroy(vc, allocator);
    self.values.destroy(vc);
}
