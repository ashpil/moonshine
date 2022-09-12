const vk = @import("vulkan");
const std = @import("std");
const Commands = @import("./Commands.zig");
const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const Object = @import("../Object.zig");

const MeshInfo = struct {
    vertex_address: vk.DeviceAddress,
    index_address: vk.DeviceAddress,
};

const MeshBuffers = std.MultiArrayList(struct {
    vertex_buffer: VkAllocator.DeviceBuffer,
    index_buffer: VkAllocator.DeviceBuffer,
});

buffers: MeshBuffers,

mesh_info: VkAllocator.DeviceBuffer,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, objects: []const Object, geometries: []vk.AccelerationStructureGeometryKHR, build_infos: []vk.AccelerationStructureBuildRangeInfoKHR) !Self {
    std.debug.assert(objects.len == geometries.len);
    std.debug.assert(objects.len == build_infos.len);

    var mesh_buffers = MeshBuffers {};
    try mesh_buffers.ensureTotalCapacity(allocator, objects.len);
    errdefer mesh_buffers.deinit(allocator);
    
    var mesh_infos = try allocator.alloc(MeshInfo, objects.len);
    defer allocator.free(mesh_infos);

    for (objects) |object, i| {
        const vertices_bytes = std.mem.sliceAsBytes(object.vertices);
        const vertex_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, vertices_bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
        errdefer vertex_buffer.destroy(vc);
        try commands.uploadData(vc, vk_allocator, vertex_buffer.handle, .{ .bytes = vertices_bytes });

        const indices_bytes = std.mem.sliceAsBytes(object.indices);
        const index_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, vertices_bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true });
        errdefer index_buffer.destroy(vc);
        try commands.uploadData(vc, vk_allocator, index_buffer.handle, .{ .bytes = indices_bytes });

        const vertex_address = vertex_buffer.getAddress(vc);
        const index_address = index_buffer.getAddress(vc);

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
            .index_buffer = index_buffer,
        });
    }

    const mesh_info_bytes = std.mem.sliceAsBytes(mesh_infos);
    const mesh_info = try vk_allocator.createDeviceBuffer(vc, allocator, mesh_info_bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true });
    errdefer mesh_info.destroy(vc);
    try commands.uploadData(vc, vk_allocator, mesh_info.handle, .{ .bytes = mesh_info_bytes });

    return Self {
        .buffers = mesh_buffers,

        .mesh_info = mesh_info,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    const slice = self.buffers.slice();
    const vertex_buffers = slice.items(.vertex_buffer);
    const index_buffers = slice.items(.index_buffer);

    var i: u32 = 0;
    while (i < slice.len) : (i += 1) {
        vertex_buffers[i].destroy(vc);
        index_buffers[i].destroy(vc);
    }
    self.buffers.deinit(allocator);

    self.mesh_info.destroy(vc);
}
