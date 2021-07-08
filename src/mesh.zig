const vk = @import("vulkan");
const std = @import("std");
const utils = @import("./utils.zig");
const VulkanContext = @import("./vulkan_context.zig").VulkanContext;

pub fn Meshes(comptime comp_vc: *VulkanContext, comptime comp_allocator: *std.mem.Allocator, TransferCommands: type) type {

    const MeshStorage = std.MultiArrayList(struct {
        vertices: vk.Buffer,
        vertices_memory: vk.DeviceMemory,
        geometry: vk.AccelerationStructureGeometryKHR,
        build_info: *const vk.AccelerationStructureBuildRangeInfoKHR,
    });

    return struct {
        storage: MeshStorage,

        const Self = @This();

        const allocator = comp_allocator;
        const vc = comp_vc;

        pub fn createOne(commands: *TransferCommands, copy_queue: vk.Queue, vertices: []const u8) !Self {
            var vertex_buffer: vk.Buffer = undefined;
            var vertex_buffer_memory: vk.DeviceMemory = undefined;
            try utils.createBuffer(vc, vertices.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true}, .{ .device_local_bit = true }, &vertex_buffer, &vertex_buffer_memory);
            errdefer vc.device.destroyBuffer(vertex_buffer, null);
            errdefer vc.device.freeMemory(vertex_buffer_memory, null);

            try commands.uploadData(copy_queue, vertex_buffer, vertices);

            // this is hardcoded for triangle, fix once we have actual model loading
            const geometry = vk.AccelerationStructureGeometryKHR {
                .geometry_type = .triangles_khr,
                .flags = .{ .opaque_bit_khr = true },
                .geometry = .{
                    .triangles = .{
                        .vertex_format = .r32g32_sfloat, 
                        .vertex_data = .{
                            .device_address = vc.device.getBufferDeviceAddress(.{
                                .buffer = vertex_buffer,
                            }),
                        },
                        .vertex_stride = @sizeOf(f32) * 2,
                        .max_vertex = 3,
                        .index_type = .none_khr,
                        .index_data = .{
                            .device_address = 0,
                        },
                        .transform_data = .{
                            .device_address = 0,
                        }
                    }
                }
            };

            // so is this (prob first only?)
            const build_info = .{
                .primitive_count = 1,
                .primitive_offset = 0,
                .transform_offset = 0,
                .first_vertex = 0,
            };

            var storage = MeshStorage {};

            try storage.append(allocator, .{
                .vertices = vertex_buffer,
                .vertices_memory = vertex_buffer_memory,
                .geometry = geometry,
                .build_info = &build_info,
            });

            return Self {
                .storage = storage,
            };
        }

        pub fn destroy(self: *Self) void {
            const slice = self.storage.slice();
            for (slice.items(.vertices)) |vertex_buffer| {
                vc.device.destroyBuffer(vertex_buffer, null);
            }
            for (slice.items(.vertices_memory)) |memory| {
                vc.device.freeMemory(memory, null);
            }
            self.storage.deinit(allocator);
        }
    };
}
