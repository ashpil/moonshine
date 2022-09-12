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
    
    var mesh_infos = try vk_allocator.createHostBuffer(vc, MeshInfo, @intCast(u32, objects.len), .{ .transfer_src_bit = true });
    defer mesh_infos.destroy(vc);

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

        mesh_infos.data[i] = MeshInfo {
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

    const mesh_info = try vk_allocator.createDeviceBuffer(vc, allocator, mesh_infos.data.len * @sizeOf(MeshInfo), .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true });
    errdefer mesh_info.destroy(vc);
    commands.recordUploadBuffer(MeshInfo, vc, mesh_info, mesh_infos);

    try commands.submitAndIdleUntilDone(vc);
    
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
