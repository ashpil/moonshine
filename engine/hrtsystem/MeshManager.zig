const vk = @import("vulkan");
const std = @import("std");

const engine = @import("../engine.zig");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Commands = core.Commands;
const VkAllocator = core.Allocator;

const vector = @import("../vector.zig");
const U32x3 = vector.Vec3(u32);
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);

// host-side mesh
pub const Mesh = struct {
    // vertices
    positions: []const F32x3,
    normals: ?[]const F32x3 = null,
    texcoords: ?[]const F32x2 = null,

    // indices
    indices: []const U32x3,

    pub fn destroy(self: *Mesh, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
        if (self.normals) |normals| allocator.free(normals);
        if (self.texcoords) |texcoords| allocator.free(texcoords);
        allocator.free(self.indices);
    }
};

// actual data we have per each mesh, CPU-side info
// probably doesn't make sense to cache addresses?
const Meshes = std.MultiArrayList(struct {
    position_buffer: VkAllocator.DeviceBuffer(F32x3),
    texcoord_buffer: VkAllocator.DeviceBuffer(F32x2),
    normal_buffer: VkAllocator.DeviceBuffer(F32x3),

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

meshes: Meshes = .{},

addresses_buffer: VkAllocator.DeviceBuffer(MeshAddresses) = .{},

const Self = @This();

const max_meshes = 512; // TODO: resizable buffers

const Handle = u32;

pub fn uploadMesh(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, host_mesh: Mesh) !Handle {
    std.debug.assert(self.meshes.len < max_meshes);
    
    var position_staging_buffer = VkAllocator.HostBuffer(F32x3) {};
    defer position_staging_buffer.destroy(vc);
    var texcoord_staging_buffer = VkAllocator.HostBuffer(F32x2) {};
    defer texcoord_staging_buffer.destroy(vc);
    var normal_staging_buffer = VkAllocator.HostBuffer(F32x3) {};
    defer normal_staging_buffer.destroy(vc);
    var index_staging_buffer = VkAllocator.HostBuffer(U32x3) {};
    defer index_staging_buffer.destroy(vc);

    try commands.startRecording(vc);
    const position_buffer = blk: {
        position_staging_buffer = try vk_allocator.createHostBuffer(vc, F32x3, host_mesh.positions.len, .{ .transfer_src_bit = true });
        @memcpy(position_staging_buffer.data, host_mesh.positions);
        const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x3, host_mesh.positions.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
        commands.recordUploadBuffer(F32x3, vc, gpu_buffer, position_staging_buffer);

        break :blk gpu_buffer;
    };
    errdefer position_buffer.destroy(vc);

    const texcoord_buffer = blk: {
        if (host_mesh.texcoords) |texcoords| {
            texcoord_staging_buffer = try vk_allocator.createHostBuffer(vc, F32x2, texcoords.len, .{ .transfer_src_bit = true });
            @memcpy(texcoord_staging_buffer.data, texcoords);
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x2, texcoords.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
            commands.recordUploadBuffer(F32x2, vc, gpu_buffer, texcoord_staging_buffer);
            break :blk gpu_buffer;
        } else {
            break :blk VkAllocator.DeviceBuffer(F32x2) {};
        }
    };
    errdefer texcoord_buffer.destroy(vc);

    const normal_buffer = blk: {
        if (host_mesh.normals) |normals| {
            normal_staging_buffer = try vk_allocator.createHostBuffer(vc, F32x3, normals.len, .{ .transfer_src_bit = true });
            @memcpy(normal_staging_buffer.data, normals);
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x3, normals.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
            commands.recordUploadBuffer(F32x3, vc, gpu_buffer, normal_staging_buffer);
            break :blk gpu_buffer;
        } else {
            break :blk VkAllocator.DeviceBuffer(F32x3) {};
        }
    };
    errdefer normal_buffer.destroy(vc);

    const index_buffer = blk: {
        index_staging_buffer = try vk_allocator.createHostBuffer(vc, U32x3, host_mesh.indices.len, .{ .transfer_src_bit = true });
        @memcpy(index_staging_buffer.data, host_mesh.indices);
        const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, U32x3, host_mesh.indices.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
        commands.recordUploadBuffer(U32x3, vc, gpu_buffer, index_staging_buffer);

        break :blk gpu_buffer;
    };
    errdefer index_buffer.destroy(vc);

    const addresses = MeshAddresses {
        .position_address = position_buffer.getAddress(vc),
        .texcoord_address = texcoord_buffer.getAddress(vc),
        .normal_address = normal_buffer.getAddress(vc) ,

        .index_address = index_buffer.getAddress(vc),
    };

    if (self.addresses_buffer.is_null()) self.addresses_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, MeshAddresses, max_meshes, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true });
    commands.recordUpdateBuffer(MeshAddresses, vc, self.addresses_buffer, &.{ addresses }, self.meshes.len);
    try commands.submitAndIdleUntilDone(vc);

    try self.meshes.append(allocator, .{
        .position_buffer = position_buffer,
        .texcoord_buffer = texcoord_buffer,
        .normal_buffer = normal_buffer,

        .vertex_count = @intCast(host_mesh.positions.len),

        .index_buffer = index_buffer,
        .index_count = @intCast(host_mesh.indices.len),

        .positions = try allocator.dupe(F32x3, host_mesh.positions),
        .indices = try allocator.dupe(U32x3, host_mesh.indices),
    });

    return @intCast(self.meshes.len - 1);
}

// can't uploadMesh if you do this
pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, host_meshes: []const Mesh) !Self {
    var meshes = Meshes {};
    try meshes.ensureTotalCapacity(allocator, host_meshes.len);
    errdefer meshes.deinit(allocator);
    
    var addresses_buffer_host = try vk_allocator.createHostBuffer(vc, MeshAddresses, @intCast(host_meshes.len), .{ .transfer_src_bit = true });
    defer addresses_buffer_host.destroy(vc);

    var staging_buffers = std.ArrayList(VkAllocator.HostBuffer(u8)).init(allocator);
    defer staging_buffers.deinit();
    defer for (staging_buffers.items) |buffer| buffer.destroy(vc);

    if (host_meshes.len != 0) try commands.startRecording(vc);

    for (host_meshes, addresses_buffer_host.data) |host_mesh, *addresses_buffer| {
        const position_buffer = blk: {
            const staging_buffer = try vk_allocator.createHostBuffer(vc, F32x3, host_mesh.positions.len, .{ .transfer_src_bit = true });
            try staging_buffers.append(staging_buffer.toBytes());
            @memcpy(staging_buffer.data, host_mesh.positions);
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x3, host_mesh.positions.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
            commands.recordUploadBuffer(F32x3, vc, gpu_buffer, staging_buffer);

            break :blk gpu_buffer;
        };
        errdefer position_buffer.destroy(vc);

        const texcoord_buffer = blk: {
            if (host_mesh.texcoords) |texcoords| {
                const staging_buffer = try vk_allocator.createHostBuffer(vc, F32x2, texcoords.len, .{ .transfer_src_bit = true });
                try staging_buffers.append(staging_buffer.toBytes());
                @memcpy(staging_buffer.data, texcoords);
                const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x2, texcoords.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
                commands.recordUploadBuffer(F32x2, vc, gpu_buffer, staging_buffer);
                break :blk gpu_buffer;
            } else {
                break :blk VkAllocator.DeviceBuffer(F32x2) {};
            }
        };
        errdefer texcoord_buffer.destroy(vc);

        const normal_buffer = blk: {
            if (host_mesh.normals) |normals| {
                const staging_buffer = try vk_allocator.createHostBuffer(vc, F32x3, normals.len, .{ .transfer_src_bit = true });
                try staging_buffers.append(staging_buffer.toBytes());
                @memcpy(staging_buffer.data, normals);
                const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, F32x3, normals.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true });
                commands.recordUploadBuffer(F32x3, vc, gpu_buffer, staging_buffer);
                break :blk gpu_buffer;
            } else {
                break :blk VkAllocator.DeviceBuffer(F32x3) {};
            }
        };
        errdefer normal_buffer.destroy(vc);

        const index_buffer = blk: {
            const staging_buffer = try vk_allocator.createHostBuffer(vc, U32x3, host_mesh.indices.len, .{ .transfer_src_bit = true });
            try staging_buffers.append(staging_buffer.toBytes());
            @memcpy(staging_buffer.data, host_mesh.indices);
            const gpu_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, U32x3, host_mesh.indices.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
            commands.recordUploadBuffer(U32x3, vc, gpu_buffer, staging_buffer);

            break :blk gpu_buffer;
        };
        errdefer index_buffer.destroy(vc);

        addresses_buffer.* = MeshAddresses {
            .position_address = position_buffer.getAddress(vc),
            .texcoord_address = texcoord_buffer.getAddress(vc),
            .normal_address = normal_buffer.getAddress(vc) ,

            .index_address = index_buffer.getAddress(vc),
        };

        meshes.appendAssumeCapacity(.{
            .position_buffer = position_buffer,
            .texcoord_buffer = texcoord_buffer,
            .normal_buffer = normal_buffer,

            .vertex_count = @intCast(host_mesh.positions.len),

            .index_buffer = index_buffer,
            .index_count = @intCast(host_mesh.indices.len),

            .positions = try allocator.dupe(F32x3, host_mesh.positions),
            .indices = try allocator.dupe(U32x3, host_mesh.indices),
        });
    }

    const addresses_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, MeshAddresses, addresses_buffer_host.data.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true });
    errdefer addresses_buffer.destroy(vc);

    if (host_meshes.len != 0) {
        commands.recordUploadBuffer(MeshAddresses, vc, addresses_buffer, addresses_buffer_host);
        try commands.submitAndIdleUntilDone(vc);
    }
    
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
        texcoord_buffer.destroy(vc);
        normal_buffer.destroy(vc);
        index_buffer.destroy(vc);
        allocator.free(position);
        allocator.free(index);
    }
    self.meshes.deinit(allocator);

    self.addresses_buffer.destroy(vc);
}
