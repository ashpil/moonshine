const vk = @import("vulkan");
const std = @import("std");
const utils = @import("./utils.zig");
const TransferCommands = @import("./commands.zig").ComputeCommands;
const VulkanContext = @import("./vulkan_context.zig");

const Vec3 = @import("./zug.zig").Vec3(f32);

pub fn Meshes(comptime comp_vc: *VulkanContext, comptime comp_allocator: *std.mem.Allocator) type {

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

        // TODO: indices
        pub fn createOne(commands: *TransferCommands(comp_vc), vertices: []const Vec3) !Self {
            const vertices_bytes = @ptrCast([*]const u8, vertices.ptr)[0..vertices.len * @sizeOf(Vec3)];

            var vertex_buffer: vk.Buffer = undefined;
            var vertex_buffer_memory: vk.DeviceMemory = undefined;
            try utils.createBuffer(vc, vertices_bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true}, .{ .device_local_bit = true }, &vertex_buffer, &vertex_buffer_memory);
            errdefer vc.device.destroyBuffer(vertex_buffer, null);
            errdefer vc.device.freeMemory(vertex_buffer_memory, null);

            try commands.uploadData(vertex_buffer, vertices_bytes);

            const geometry = vk.AccelerationStructureGeometryKHR {
                .geometry_type = .triangles_khr,
                .flags = .{ .opaque_bit_khr = true },
                .geometry = .{
                    .triangles = .{
                        .vertex_format = .r32g32b32_sfloat, 
                        .vertex_data = .{
                            .device_address = vc.device.getBufferDeviceAddress(.{
                                .buffer = vertex_buffer,
                            }),
                        },
                        .vertex_stride = @sizeOf(Vec3),
                        .max_vertex = @intCast(u32, vertices.len - 1),
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
