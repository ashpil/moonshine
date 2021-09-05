const vk = @import("vulkan");
const std = @import("std");
const utils = @import("./utils.zig");
const TransferCommands = @import("./commands.zig").ComputeCommands;
const VulkanContext = @import("./VulkanContext.zig");
const Object = @import("../utils/Object.zig");

const f32x3 = @import("../utils/zug.zig").Vec3(f32);
const u32x3 = @import("../utils/zug.zig").Vec3(u32);

const MeshInfo = struct {
    vertex_address: vk.DeviceAddress,
    index_address: vk.DeviceAddress,
};

const MeshBuffers = std.MultiArrayList(struct {
    vertex_buffer: vk.Buffer,
    vertex_buffer_memory: vk.DeviceMemory,

    index_buffer: vk.Buffer,
    index_buffer_memory: vk.DeviceMemory,
});

buffers: MeshBuffers,

mesh_info: vk.Buffer,
mesh_info_memory: vk.DeviceMemory,

const Self = @This();

pub fn create(vc: *const VulkanContext, commands: *TransferCommands, allocator: *std.mem.Allocator, objects: []const Object, geometries: []vk.AccelerationStructureGeometryKHR, build_infos: []vk.AccelerationStructureBuildRangeInfoKHR) !Self {
    std.debug.assert(objects.len == geometries.len);
    std.debug.assert(objects.len == build_infos.len);

    var mesh_buffers = MeshBuffers {};
    try mesh_buffers.ensureTotalCapacity(allocator, objects.len);
    errdefer mesh_buffers.deinit(allocator);
    
    var mesh_infos = try allocator.alloc(MeshInfo, objects.len);
    defer allocator.free(mesh_infos);

    for (objects) |object, i| {
        const vertices_bytes = std.mem.sliceAsBytes(object.vertices);

        var vertex_buffer: vk.Buffer = undefined;
        var vertex_buffer_memory: vk.DeviceMemory = undefined;
        try utils.createBuffer(vc, vertices_bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }, .{ .device_local_bit = true }, &vertex_buffer, &vertex_buffer_memory);
        errdefer vc.device.destroyBuffer(vertex_buffer, null);
        errdefer vc.device.freeMemory(vertex_buffer_memory, null);
        try commands.uploadData(vc, vertex_buffer, vertices_bytes);

        var index_buffer: vk.Buffer = undefined;
        var index_buffer_memory: vk.DeviceMemory = undefined;
        const indices_bytes = std.mem.sliceAsBytes(object.indices);
        try utils.createBuffer(vc, indices_bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true }, .{ .device_local_bit = true }, &index_buffer, &index_buffer_memory);
        errdefer vc.device.destroyBuffer(index_buffer, null);
        errdefer vc.device.freeMemory(index_buffer_memory, null);
        try commands.uploadData(vc, index_buffer, indices_bytes);

        const vertex_address = vc.device.getBufferDeviceAddress(.{
            .buffer = vertex_buffer,
        });
        const index_address = vc.device.getBufferDeviceAddress(.{
            .buffer = index_buffer,
        });

        mesh_infos[i] = MeshInfo {
            .vertex_address = vertex_address,
            .index_address = index_address,
        };
        geometries[i] = vk.AccelerationStructureGeometryKHR {
            .geometry_type = .triangles_khr,
            .flags = .{ .opaque_bit_khr = true },
            .geometry = .{
                .triangles = .{
                    .vertex_format = .r32g32b32_sfloat, 
                    .vertex_data = .{
                        .device_address = vertex_address,
                    },
                    .vertex_stride = @sizeOf(@TypeOf(object.vertices[0])),
                    .max_vertex = @intCast(u32, object.vertices.len - 1),
                    .index_type = .uint32,
                    .index_data = .{
                        .device_address = index_address,
                    },
                    .transform_data = .{
                        .device_address = 0,
                    }
                }
            }
        };

        build_infos[i] = vk.AccelerationStructureBuildRangeInfoKHR {
            .primitive_count = @intCast(u32, object.indices.len),
            .primitive_offset = 0,
            .transform_offset = 0,
            .first_vertex = 0,
        };

        mesh_buffers.appendAssumeCapacity(.{
            .vertex_buffer = vertex_buffer,
            .vertex_buffer_memory = vertex_buffer_memory,

            .index_buffer = index_buffer,
            .index_buffer_memory = index_buffer_memory,
        });
    }

    const mesh_info_bytes = std.mem.sliceAsBytes(mesh_infos);
    var mesh_info: vk.Buffer = undefined;
    var mesh_info_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, mesh_info_bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true }, .{ .device_local_bit = true }, &mesh_info, &mesh_info_memory);
    errdefer vc.device.destroyBuffer(mesh_info, null);
    errdefer vc.device.freeMemory(mesh_info_memory, null);
    try commands.uploadData(vc, mesh_info, mesh_info_bytes);

    return Self {
        .buffers = mesh_buffers,

        .mesh_info = mesh_info,
        .mesh_info_memory = mesh_info_memory,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator) void {
    const slice = self.buffers.slice();
    const vertex_buffers = slice.items(.vertex_buffer);
    const vertex_buffers_memory = slice.items(.vertex_buffer_memory);

    const index_buffers = slice.items(.index_buffer);
    const index_buffers_memory = slice.items(.index_buffer_memory);

    var i: u32 = 0;
    while (i < slice.len) : (i += 1) {
        vc.device.destroyBuffer(vertex_buffers[i], null);
        vc.device.freeMemory(vertex_buffers_memory[i], null);

        vc.device.destroyBuffer(index_buffers[i], null);
        vc.device.freeMemory(index_buffers_memory[i], null);
    }
    
    self.buffers.deinit(allocator);

    vc.device.destroyBuffer(self.mesh_info, null);
    vc.device.freeMemory(self.mesh_info_memory, null);
}