const vk = @import("vulkan");
const std = @import("std");
const Commands = @import("./Commands.zig");
const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const Object = @import("../Object.zig");

const vector = @import("../vector.zig");
const U32x3 = vector.Vec3(u32);
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);

// actual data we have per each mesh, CPU-side info
// probably doesn't make sense to cache addresses?
const Meshes = std.MultiArrayList(struct {
    position_buffer: VkAllocator.DeviceBuffer(F32x3),
    texcoord_buffer: ?VkAllocator.DeviceBuffer(F32x2), // hmm is there any way to get this to take up same size as a non-nullable buffer?
    normal_buffer: ?VkAllocator.DeviceBuffer(F32x3), // and this

    vertex_count: u32,

    index_buffer: VkAllocator.DeviceBuffer(U32x3),
    index_count: u32,

    // data on host side -- atm only used for alias table construction for explicit samping
    positions: []const F32x3,
    indices: []const U32x3,
});

// store seperately to be able to get pointers to geometry data in shader
const MeshAddresses = packed struct {
    position_address: vk.DeviceAddress,
    texcoord_address: vk.DeviceAddress,
    normal_address: vk.DeviceAddress,

    index_address: vk.DeviceAddress,
};

meshes: Meshes,

addresses_buffer: VkAllocator.DeviceBuffer(MeshAddresses),

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

    for (objects, addresses_buffer_host.data) |object, *addresses_buffer| {
        const position_buffer = blk: {
            const staging_buffer = try vk_allocator.createHostBuffer(vc, F32x3, object.positions.len, .{ .transfer_src_bit = true });
            try staging_buffers.append(staging_buffer.toBytes());
            std.mem.copy(F32x3, staging_buffer.data, object.positions);
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x3, object.positions.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
            commands.recordUploadBuffer(F32x3, vc, gpu_buffer, staging_buffer);

            break :blk gpu_buffer;
        };
        errdefer position_buffer.destroy(vc);

        const texcoord_buffer = blk: {
            if (object.texcoords) |texcoords| {
                const staging_buffer = try vk_allocator.createHostBuffer(vc, F32x2, texcoords.len, .{ .transfer_src_bit = true });
                try staging_buffers.append(staging_buffer.toBytes());
                std.mem.copy(F32x2, staging_buffer.data, texcoords);
                const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x2, texcoords.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
                commands.recordUploadBuffer(F32x2, vc, gpu_buffer, staging_buffer);
                break :blk gpu_buffer;
            } else {
                break :blk null;
            }
        };
        errdefer if (texcoord_buffer) |buffer| buffer.destroy(vc);

        const normal_buffer = blk: {
            if (object.normals) |normals| {
                const staging_buffer = try vk_allocator.createHostBuffer(vc, F32x3, normals.len, .{ .transfer_src_bit = true });
                try staging_buffers.append(staging_buffer.toBytes());

                std.mem.copy(F32x3, staging_buffer.data, normals);
                const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x3, normals.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
                commands.recordUploadBuffer(F32x3, vc, gpu_buffer, staging_buffer);
                break :blk gpu_buffer;
            } else {
                break :blk null;
            }
        };
        errdefer if (normal_buffer) |buffer| buffer.destroy(vc);

        const index_buffer = blk: {
            const staging_buffer = try vk_allocator.createHostBuffer(vc, U32x3, object.indices.len, .{ .transfer_src_bit = true });
            try staging_buffers.append(staging_buffer.toBytes());
            std.mem.copy(U32x3, staging_buffer.data, object.indices);
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, U32x3, object.indices.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
            commands.recordUploadBuffer(U32x3, vc, gpu_buffer, staging_buffer);

            break :blk gpu_buffer;
        };
        errdefer index_buffer.destroy(vc);

        addresses_buffer.* = MeshAddresses {
            .position_address = position_buffer.getAddress(vc),
            .texcoord_address = if (texcoord_buffer) |buffer| buffer.getAddress(vc) else 0,
            .normal_address = if (normal_buffer) |buffer| buffer.getAddress(vc) else 0,

            .index_address = index_buffer.getAddress(vc),
        };

        meshes.appendAssumeCapacity(.{
            .position_buffer = position_buffer,
            .texcoord_buffer = texcoord_buffer,
            .normal_buffer = normal_buffer,

            .vertex_count = @intCast(u32, object.positions.len),

            .index_buffer = index_buffer,
            .index_count = @intCast(u32, object.indices.len),

            .positions = try allocator.dupe(F32x3, object.positions),
            .indices = try allocator.dupe(U32x3, object.indices),
        });
    }

    const addresses_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, MeshAddresses, addresses_buffer_host.data.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true });
    errdefer addresses_buffer.destroy(vc);
    commands.recordUploadBuffer(MeshAddresses, vc, addresses_buffer, addresses_buffer_host);

    try commands.submitAndIdleUntilDone(vc);
    
    return Self {
        .meshes = meshes,
        .addresses_buffer = addresses_buffer,
    };
}

pub fn fromMsne(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, reader: anytype) !Self {
    const mesh_count = try reader.readIntLittle(u32);
    var meshes = Meshes {};
    try meshes.ensureTotalCapacity(allocator, mesh_count);
    errdefer meshes.deinit(allocator);
    
    var addresses_buffer_host = try vk_allocator.createHostBuffer(vc, MeshAddresses, mesh_count, .{ .transfer_src_bit = true });
    defer addresses_buffer_host.destroy(vc);

    var staging_buffers = std.ArrayList(VkAllocator.HostBuffer(u8)).init(allocator);
    defer staging_buffers.deinit();
    defer for (staging_buffers.items) |buffer| buffer.destroy(vc);

    try commands.startRecording(vc);

    for (addresses_buffer_host.data) |*addresses_buffer| {
        const index_count = try reader.readIntLittle(u32);
        const index_staging_buffer = try vk_allocator.createHostBuffer(vc, U32x3, index_count, .{ .transfer_src_bit = true });
        const index_buffer = blk: {
            try staging_buffers.append(index_staging_buffer.toBytes());
            try reader.readNoEof(std.mem.sliceAsBytes(index_staging_buffer.data));
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, U32x3, index_count, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
            commands.recordUploadBuffer(U32x3, vc, gpu_buffer, index_staging_buffer);

            break :blk gpu_buffer;
        };
        errdefer index_buffer.destroy(vc);

        const vertex_count = try reader.readIntLittle(u32);

        const position_staging_buffer = try vk_allocator.createHostBuffer(vc, F32x3, vertex_count, .{ .transfer_src_bit = true });
        const position_buffer = blk: {
            try staging_buffers.append(position_staging_buffer.toBytes());
            try reader.readNoEof(std.mem.sliceAsBytes(position_staging_buffer.data));
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x3, vertex_count, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
            commands.recordUploadBuffer(F32x3, vc, gpu_buffer, position_staging_buffer);

            break :blk gpu_buffer;
        };
        errdefer position_buffer.destroy(vc);

        const normal_buffer = if (try reader.readByte() != 0) blk: {
            const staging_buffer = try vk_allocator.createHostBuffer(vc, F32x3, vertex_count, .{ .transfer_src_bit = true });
            try staging_buffers.append(staging_buffer.toBytes());
            try reader.readNoEof(std.mem.sliceAsBytes(staging_buffer.data));
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x3, vertex_count, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
            commands.recordUploadBuffer(F32x3, vc, gpu_buffer, staging_buffer);
            break :blk gpu_buffer;
        } else null;
        errdefer if (normal_buffer) |buffer| buffer.destroy(vc);

        const texcoord_buffer = if (try reader.readByte() != 0) blk: {
            const staging_buffer = try vk_allocator.createHostBuffer(vc, F32x2, vertex_count, .{ .transfer_src_bit = true });
            try staging_buffers.append(staging_buffer.toBytes());
            try reader.readNoEof(std.mem.sliceAsBytes(staging_buffer.data));
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x2, vertex_count, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
            commands.recordUploadBuffer(F32x2, vc, gpu_buffer, staging_buffer);
            break :blk gpu_buffer;
        } else null;
        errdefer if (texcoord_buffer) |buffer| buffer.destroy(vc);

        addresses_buffer.* = MeshAddresses {
            .position_address = position_buffer.getAddress(vc),
            .normal_address = if (normal_buffer) |buffer| buffer.getAddress(vc) else 0,
            .texcoord_address = if (texcoord_buffer) |buffer| buffer.getAddress(vc) else 0,

            .index_address = index_buffer.getAddress(vc),
        };

        meshes.appendAssumeCapacity(.{
            .position_buffer = position_buffer,
            .texcoord_buffer = texcoord_buffer,
            .normal_buffer = normal_buffer,

            .vertex_count = vertex_count,

            .index_buffer = index_buffer,
            .index_count = index_count,

            .positions = try allocator.dupe(F32x3, position_staging_buffer.data),
            .indices = try allocator.dupe(U32x3, index_staging_buffer.data),
        });
    }

    const addresses_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, MeshAddresses, addresses_buffer_host.data.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true });
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
    const positions = slice.items(.positions);
    const indices = slice.items(.indices);

    for (position_buffers, texcoord_buffers, normal_buffers, index_buffers, positions, indices) |position_buffer, texcoord_buffer, normal_buffer, index_buffer, position, index| {
        position_buffer.destroy(vc);
        if (texcoord_buffer) |buffer| buffer.destroy(vc);
        if (normal_buffer) |buffer| buffer.destroy(vc);
        index_buffer.destroy(vc);
        allocator.free(position);
        allocator.free(index);
    }
    self.meshes.deinit(allocator);

    self.addresses_buffer.destroy(vc);
}
