const vk = @import("vulkan");
const std = @import("std");
const Commands = @import("./Commands.zig");
const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const Object = @import("../Object.zig");

// actual data we have per each mesh, CPU-side info
// probably doesn't make sense to cache addresses?
const Meshes = std.MultiArrayList(struct {
    position_buffer: VkAllocator.DeviceBuffer,
    texcoord_buffer: ?VkAllocator.DeviceBuffer, // hmm is there any way to get this to take up same size as a non-nullable buffer?
    normal_buffer: ?VkAllocator.DeviceBuffer, // and this

    vertex_count: u32,

    index_buffer: VkAllocator.DeviceBuffer,
    index_count: u32,
});

// store seperately to be able to get pointers to geometry data in shader
const MeshAddresses = packed struct {
    position_address: vk.DeviceAddress,
    texcoord_address: vk.DeviceAddress,
    normal_address: vk.DeviceAddress,

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

    var staging_buffers = std.ArrayList(VkAllocator.HostBuffer(u8)).init(allocator);
    defer staging_buffers.deinit();
    defer for (staging_buffers.items) |buffer| buffer.destroy(vc);

    try commands.startRecording(vc);

    for (objects) |object, i| {
        const position_buffer = blk: {
            const bytes = std.mem.sliceAsBytes(object.positions);

            const staging_buffer = try staging_buffers.addOne();
            staging_buffer.* = try vk_allocator.createHostBuffer(vc, u8, @intCast(u32, bytes.len), .{ .transfer_src_bit = true });
            std.mem.copy(u8, staging_buffer.data, bytes);
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
            commands.recordUploadBuffer(u8, vc, gpu_buffer, staging_buffer.*);

            break :blk gpu_buffer;
        };
        errdefer position_buffer.destroy(vc);

        const texcoord_buffer = blk: {
            if (object.texcoords) |texcoords| {
                const bytes = std.mem.sliceAsBytes(texcoords);

                const staging_buffer = try staging_buffers.addOne();
                staging_buffer.* = try vk_allocator.createHostBuffer(vc, u8, @intCast(u32, bytes.len), .{ .transfer_src_bit = true });
                std.mem.copy(u8, staging_buffer.data, bytes);
                const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
                commands.recordUploadBuffer(u8, vc, gpu_buffer, staging_buffer.*);
                break :blk gpu_buffer;
            } else {
                break :blk null;
            }
        };
        errdefer if (texcoord_buffer) |buffer| buffer.destroy(vc);

        const normal_buffer = blk: {
            if (object.normals) |normals| {
                const bytes = std.mem.sliceAsBytes(normals);

                const staging_buffer = try staging_buffers.addOne();
                staging_buffer.* = try vk_allocator.createHostBuffer(vc, u8, @intCast(u32, bytes.len), .{ .transfer_src_bit = true });
                std.mem.copy(u8, staging_buffer.data, bytes);
                const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
                commands.recordUploadBuffer(u8, vc, gpu_buffer, staging_buffer.*);
                break :blk gpu_buffer;
            } else {
                break :blk null;
            }
        };
        errdefer if (normal_buffer) |buffer| buffer.destroy(vc);

        const index_buffer = blk: {
            const bytes = std.mem.sliceAsBytes(object.indices);

            const staging_buffer = try staging_buffers.addOne();
            staging_buffer.* = try vk_allocator.createHostBuffer(vc, u8, @intCast(u32, bytes.len), .{ .transfer_src_bit = true });
            std.mem.copy(u8, staging_buffer.data, bytes);
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
            commands.recordUploadBuffer(u8, vc, gpu_buffer, staging_buffer.*);

            break :blk gpu_buffer;
        };
        errdefer index_buffer.destroy(vc);

        addresses_buffer_host.data[i] = MeshAddresses {
            .position_address = position_buffer.getAddress(vc),
            .texcoord_address = if (texcoord_buffer) |buffer| buffer.getAddress(vc) else 0,
            .normal_address = if (normal_buffer) |buffer| buffer.getAddress(vc) else 0,

            .index_address = index_buffer.getAddress(vc),
        };

        meshes.appendAssumeCapacity(.{
            .position_buffer = position_buffer,
            .texcoord_buffer = texcoord_buffer,
            .normal_buffer = normal_buffer,

            .vertex_count = @intCast(u32, object.positions.len), // should be same as indices

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
    const position_buffers = slice.items(.position_buffer);
    const texcoord_buffers = slice.items(.texcoord_buffer);
    const normal_buffers = slice.items(.normal_buffer);
    const index_buffers = slice.items(.index_buffer);

    var i: u32 = 0;
    while (i < slice.len) : (i += 1) {
        position_buffers[i].destroy(vc);
        if (texcoord_buffers[i]) |buffer| buffer.destroy(vc);
        if (normal_buffers[i]) |buffer| buffer.destroy(vc);
        index_buffers[i].destroy(vc);
    }
    self.meshes.deinit(allocator);

    self.addresses_buffer.destroy(vc);
}
