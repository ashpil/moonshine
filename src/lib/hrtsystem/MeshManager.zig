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

pub const Mesh = struct {
    pub const Parameters = struct {
        name: []const u8,
        // vertices
        positions: core.mem.BufferSlice(F32x3),
        normals: ?core.mem.BufferSlice(F32x3),
        texcoords: ?core.mem.BufferSlice(F32x2),

        // indices
        indices: ?core.mem.BufferSlice(U32x3),
    };

    pub const Host = struct {
        position_buffer: core.mem.DeviceBuffer(F32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }),
        texcoord_buffer: core.mem.DeviceBuffer(F32x2, .{ .shader_device_address_bit = true, .transfer_dst_bit = true }),
        normal_buffer: core.mem.DeviceBuffer(F32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true }),

        vertex_count: u32,

        index_buffer: core.mem.DeviceBuffer(U32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }),
        index_count: u32,
    };

    pub const Device = extern struct {
        position_address: vk.DeviceAddress,
        texcoord_address: vk.DeviceAddress,
        normal_address: vk.DeviceAddress,

        index_address: vk.DeviceAddress,
    };
};

host: std.MultiArrayList(Mesh.Host) = .{},
device: core.mem.DeviceBuffer(Mesh.Device, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true }) = .{},

const Self = @This();

const max_meshes = 4096; // TODO: resizable buffers

pub const Handle = u32;

pub fn upload(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, parameters: Mesh.Parameters) !Handle {
    std.debug.assert(self.host.len < max_meshes);

    const position_buffer = blk: {
        const buffer_name = try std.fmt.allocPrintZ(allocator, "mesh {s} positions", .{ parameters.name });
        defer allocator.free(buffer_name);
        const gpu_buffer = try core.mem.DeviceBuffer(F32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }).create(vc, parameters.positions.len, buffer_name);
        gpu_buffer.uploadFrom(encoder, 0, parameters.positions);

        break :blk gpu_buffer;
    };
    errdefer position_buffer.destroy(vc);

    const texcoord_buffer = blk: {
        if (parameters.texcoords) |texcoords| {
            const buffer_name = try std.fmt.allocPrintZ(allocator, "mesh {s} texcoords", .{ parameters.name });
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
        if (parameters.normals) |normals| {
            const buffer_name = try std.fmt.allocPrintZ(allocator, "mesh {s} normals", .{ parameters.name });
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
        if (parameters.indices) |indices| {
            const buffer_name = try std.fmt.allocPrintZ(allocator, "mesh {s} incides", .{ parameters.name });
            defer allocator.free(buffer_name);
            const gpu_buffer = try core.mem.DeviceBuffer(U32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }).create(vc, indices.len, buffer_name);
            gpu_buffer.uploadFrom(encoder, 0, indices);
            break :blk gpu_buffer;
        } else {
            break :blk core.mem.DeviceBuffer(U32x3, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }) {};
        }
    };
    errdefer index_buffer.destroy(vc);

    const device = Mesh.Device {
        .position_address = position_buffer.getAddress(vc),
        .texcoord_address = texcoord_buffer.getAddress(vc),
        .normal_address = normal_buffer.getAddress(vc) ,

        .index_address = index_buffer.getAddress(vc),
    };

    if (self.device.isNull()) self.device = try core.mem.DeviceBuffer(Mesh.Device, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true }).create(vc, max_meshes, "meshes");
    self.device.updateFrom(encoder, self.host.len, &.{ device });

    try self.host.append(allocator, .{
        .position_buffer = position_buffer,
        .texcoord_buffer = texcoord_buffer,
        .normal_buffer = normal_buffer,

        .vertex_count = @intCast(parameters.positions.len),

        .index_buffer = index_buffer,
        .index_count = if (parameters.indices) |indices| @intCast(indices.len) else 0,
    });

    return @intCast(self.host.len - 1);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    const slice = self.host.slice();
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
    self.host.deinit(allocator);

    self.device.destroy(vc);
}
