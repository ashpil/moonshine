const vk = @import("vulkan");
const std = @import("std");
const Commands = @import("./Commands.zig");
const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const Object = @import("../Object.zig");

// actual data we have per each mesh, CPU-side info
// probably doesn't make sense to cache addresses?
const Meshes = std.MultiArrayList(struct {
    vertex_buffer: VkAllocator.DeviceBuffer,
    vertex_count: u32,

    index_buffer: VkAllocator.DeviceBuffer,
    index_count: u32,
});

// store seperately to be able to get pointers to geometry data in shader
const MeshAddresses = packed struct {
    vertex_address: vk.DeviceAddress,
    index_address: vk.DeviceAddress,
};

meshes: Meshes,

addresses_buffer: VkAllocator.DeviceBuffer,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, objects: []const Object) !Self {
    var meshes = Meshes {};
    try meshes.ensureTotalCapacity(allocator, objects.len);
    errdefer meshes.deinit(allocator);
    
    var addresses_buffer_host = try vk_allocator.createHostBuffer(vc, MeshAddresses, @intCast(u32, objects.len), .{ .transfer_src_bit = true });
    defer addresses_buffer_host.destroy(vc);

    var staging_buffers = try allocator.alloc(VkAllocator.HostBuffer(u8), objects.len * 2);
    defer allocator.free(staging_buffers);
    defer for (staging_buffers) |buffer| buffer.destroy(vc);

    try commands.startRecording(vc);

    for (objects) |object, i| {
        const vertex_buffer = blk: {
            const bytes = std.mem.sliceAsBytes(object.vertices);

            staging_buffers[i] = try vk_allocator.createHostBuffer(vc, u8, @intCast(u32, bytes.len), .{ .transfer_src_bit = true });
            std.mem.copy(u8, staging_buffers[i].data, bytes);
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
            commands.recordUploadBuffer(u8, vc, gpu_buffer, staging_buffers[i]);

            break :blk gpu_buffer;
        };
        errdefer vertex_buffer.destroy(vc);

        const index_buffer = blk: {
            const bytes = std.mem.sliceAsBytes(object.indices);

            staging_buffers[objects.len + i] = try vk_allocator.createHostBuffer(vc, u8, @intCast(u32, bytes.len), .{ .transfer_src_bit = true });
            std.mem.copy(u8, staging_buffers[objects.len + i].data, bytes);
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
            commands.recordUploadBuffer(u8, vc, gpu_buffer, staging_buffers[objects.len + i]);

            break :blk gpu_buffer;
        };
        errdefer index_buffer.destroy(vc);

        const vertex_address = vertex_buffer.getAddress(vc);
        const index_address = index_buffer.getAddress(vc);

        addresses_buffer_host.data[i] = MeshAddresses {
            .vertex_address = vertex_address,
            .index_address = index_address,
        };

        meshes.appendAssumeCapacity(.{
            .vertex_buffer = vertex_buffer,
            .vertex_count = @intCast(u32, object.vertices.len),

            .index_buffer = index_buffer,
            .index_count = @intCast(u32, object.indices.len),
        });
    }

    const addresses_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, addresses_buffer_host.data.len * @sizeOf(MeshAddresses), .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true });
    errdefer addresses_buffer.destroy(vc);
    commands.recordUploadBuffer(MeshAddresses, vc, addresses_buffer, addresses_buffer_host);

    try commands.submitAndIdleUntilDone(vc);
    
    return Self {
        .meshes = meshes,
        .addresses_buffer = addresses_buffer,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    const slice = self.meshes.slice();
    const vertex_buffers = slice.items(.vertex_buffer);
    const index_buffers = slice.items(.index_buffer);

    var i: u32 = 0;
    while (i < slice.len) : (i += 1) {
        vertex_buffers[i].destroy(vc);
        index_buffers[i].destroy(vc);
    }
    self.meshes.deinit(allocator);

    self.addresses_buffer.destroy(vc);
}
