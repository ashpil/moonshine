const vk = @import("vulkan");
const std = @import("std");

const engine = @import("../engine.zig");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;

const vector = @import("../vector.zig");
const U32x3 = vector.Vec3(u32);
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);

// host-side mesh
pub const Mesh = struct {
    name: []const u8,
    // vertices
    positions: core.mem.BufferSlice(F32x3),
    normals: ?core.mem.BufferSlice(F32x3),
    texcoords: ?core.mem.BufferSlice(F32x2),

    // indices
    indices: ?core.mem.BufferSlice(U32x3),
};

// actual data we have per each mesh, GPU-side info
// probably doesn't make sense to cache addresses?
const Meshes = std.MultiArrayList(struct {
    position_buffer: core.mem.DeviceBuffer(F32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }),
    texcoord_buffer: core.mem.DeviceBuffer(F32x2, .{ .shader_device_address_bit = true, .transfer_dst_bit = true }),
    normal_buffer: core.mem.DeviceBuffer(F32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true }),

    vertex_count: u32,

    index_buffer: core.mem.DeviceBuffer(U32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }),
    index_count: u32,
});

// store seperately to be able to get pointers to geometry data in shader
const MeshAddresses = packed struct {
    position_address: vk.DeviceAddress,
    texcoord_address: vk.DeviceAddress,
    normal_address: vk.DeviceAddress,

    index_address: vk.DeviceAddress,
};

meshes: Meshes = .{},

addresses_buffer: core.mem.DeviceBuffer(MeshAddresses, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true }) = .{},

const Self = @This();

const max_meshes = 4096; // TODO: resizable buffers

pub const Handle = u32;

pub fn upload(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, host_mesh: Mesh) !Handle {
    std.debug.assert(self.meshes.len < max_meshes);

    const position_buffer = blk: {
        const buffer_name = try std.fmt.allocPrintZ(allocator, "mesh {s} positions", .{ host_mesh.name });
        defer allocator.free(buffer_name);
        const gpu_buffer = try core.mem.DeviceBuffer(F32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }).create(vc, host_mesh.positions.len, buffer_name);
        gpu_buffer.uploadFrom(encoder, 0, host_mesh.positions);

        break :blk gpu_buffer;
    };
    errdefer position_buffer.destroy(vc);

    const texcoord_buffer = blk: {
        if (host_mesh.texcoords) |texcoords| {
            const buffer_name = try std.fmt.allocPrintZ(allocator, "mesh {s} texcoords", .{ host_mesh.name });
            defer allocator.free(buffer_name);
            const gpu_buffer = try core.mem.DeviceBuffer(F32x2, .{ .shader_device_address_bit = true, .transfer_dst_bit = true }).create(vc, texcoords.len, buffer_name);
            gpu_buffer.uploadFrom(encoder, 0, texcoords);
            break :blk gpu_buffer;
        } else {
            break :blk core.mem.DeviceBuffer(F32x2, .{ .shader_device_address_bit = true, .transfer_dst_bit = true }) {};
        }
    };
    errdefer texcoord_buffer.destroy(vc);

    const normal_buffer = blk: {
        if (host_mesh.normals) |normals| {
            const buffer_name = try std.fmt.allocPrintZ(allocator, "mesh {s} normals", .{ host_mesh.name });
            defer allocator.free(buffer_name);
            const gpu_buffer = try core.mem.DeviceBuffer(F32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true }).create(vc, normals.len, buffer_name);
            gpu_buffer.uploadFrom(encoder, 0, normals);
            break :blk gpu_buffer;
        } else {
            break :blk core.mem.DeviceBuffer(F32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true }) {};
        }
    };
    errdefer normal_buffer.destroy(vc);

    const index_buffer = blk: {
        if (host_mesh.indices) |indices| {
            const buffer_name = try std.fmt.allocPrintZ(allocator, "mesh {s} incides", .{ host_mesh.name });
            defer allocator.free(buffer_name);
            const gpu_buffer = try core.mem.DeviceBuffer(U32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }).create(vc, indices.len, buffer_name);
            gpu_buffer.uploadFrom(encoder, 0, indices);
            break :blk gpu_buffer;
        } else {
            break :blk core.mem.DeviceBuffer(U32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }) {};
        }
    };
    errdefer index_buffer.destroy(vc);

    const addresses = MeshAddresses {
        .position_address = position_buffer.getAddress(vc),
        .texcoord_address = texcoord_buffer.getAddress(vc),
        .normal_address = normal_buffer.getAddress(vc) ,

        .index_address = index_buffer.getAddress(vc),
    };

    if (self.addresses_buffer.isNull()) self.addresses_buffer = try core.mem.DeviceBuffer(MeshAddresses, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true }).create(vc, max_meshes, "mesh addresses");
    self.addresses_buffer.updateFrom(encoder, self.meshes.len, &.{ addresses });

    try self.meshes.append(allocator, .{
        .position_buffer = position_buffer,
        .texcoord_buffer = texcoord_buffer,
        .normal_buffer = normal_buffer,

        .vertex_count = @intCast(host_mesh.positions.len),

        .index_buffer = index_buffer,
        .index_count = if (host_mesh.indices) |indices| @intCast(indices.len) else 0,
    });

    return @intCast(self.meshes.len - 1);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    const slice = self.meshes.slice();
    const position_buffers = slice.items(.position_buffer);
    const texcoord_buffers = slice.items(.texcoord_buffer);
    const normal_buffers = slice.items(.normal_buffer);
    const index_buffers = slice.items(.index_buffer);

    for (position_buffers, texcoord_buffers, normal_buffers, index_buffers) |position_buffer, texcoord_buffer, normal_buffer, index_buffer| {
        position_buffer.destroy(vc);
        texcoord_buffer.destroy(vc);
        normal_buffer.destroy(vc);
        index_buffer.destroy(vc);
    }
    self.meshes.deinit(allocator);

    self.addresses_buffer.destroy(vc);
}
