const vk = @import("vulkan");
const std = @import("std");
const utils = @import("./utils.zig");
const TransferCommands = @import("./commands.zig").ComputeCommands;
const VulkanContext = @import("./VulkanContext.zig");
const Object = @import("./Object.zig");

const f32x3 = @import("./zug.zig").Vec3(f32);
const u32x3 = @import("./zug.zig").Vec3(u32);

pub fn Meshes(comptime mesh_count: comptime_int) type {
    return struct {
        const MeshInfo = struct {
            vertex_address: vk.DeviceAddress,
            index_address: vk.DeviceAddress,
            material: Object.Material,
        };

        vertices: [mesh_count]vk.Buffer,
        vertices_memory: [mesh_count]vk.DeviceMemory,

        indices: [mesh_count]vk.Buffer,
        indices_memory: [mesh_count]vk.DeviceMemory,

        mesh_info: vk.Buffer,
        mesh_info_memory: vk.DeviceMemory,

        const Self = @This();

        pub fn create(vc: *const VulkanContext, commands: *TransferCommands, objects: *const [mesh_count]Object, geometries: *[mesh_count]vk.AccelerationStructureGeometryKHR, build_infos: *[mesh_count]vk.AccelerationStructureBuildRangeInfoKHR) !Self {
            var vertices: [mesh_count]vk.Buffer = undefined;
            var vertices_memory: [mesh_count]vk.DeviceMemory = undefined;

            var indices: [mesh_count]vk.Buffer = undefined;
            var indices_memory: [mesh_count]vk.DeviceMemory = undefined;

            var mesh_infos: [mesh_count]MeshInfo = undefined;

            for (objects) |object, i| {
                const vertices_bytes = std.mem.sliceAsBytes(object.vertices);
                try utils.createBuffer(vc, vertices_bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true}, .{ .device_local_bit = true }, &vertices[i], &vertices_memory[i]);
                errdefer vc.device.destroyBuffer(vertices[i], null);
                errdefer vc.device.freeMemory(vertices_memory[i], null);
                try commands.uploadData(vc, vertices[i], vertices_bytes);

                const indices_bytes = std.mem.sliceAsBytes(object.indices);
                try utils.createBuffer(vc, indices_bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true}, .{ .device_local_bit = true }, &indices[i], &indices_memory[i]);
                errdefer vc.device.destroyBuffer(indices[i], null);
                errdefer vc.device.freeMemory(indices_memory[i], null);
                try commands.uploadData(vc, indices[i], indices_bytes);

                const vertex_address = vc.device.getBufferDeviceAddress(.{
                    .buffer = vertices[i],
                });
                const index_address = vc.device.getBufferDeviceAddress(.{
                    .buffer = indices[i],
                });
                mesh_infos[i] = MeshInfo {
                    .vertex_address = vertex_address,
                    .index_address = index_address,
                    .material = object.material,
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
            }

            const mesh_info_bytes = std.mem.asBytes(&mesh_infos);
            var mesh_info: vk.Buffer = undefined;
            var mesh_info_memory: vk.DeviceMemory = undefined;
            try utils.createBuffer(vc, mesh_info_bytes.len, .{ .shader_device_address_bit = true, .transfer_dst_bit = true, .storage_buffer_bit = true }, .{ .device_local_bit = true }, &mesh_info, &mesh_info_memory);
            errdefer vc.device.destroyBuffer(mesh_info, null);
            errdefer vc.device.freeMemory(mesh_info_memory, null);
            try commands.uploadData(vc, mesh_info, mesh_info_bytes);

            return Self {
                .vertices = vertices,
                .vertices_memory = vertices_memory,

                .indices = indices,
                .indices_memory = indices_memory,

                .mesh_info = mesh_info,
                .mesh_info_memory = mesh_info_memory,
            };
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            comptime var i: u32 = 0;
            inline while (i < mesh_count) : (i += 1) {
                vc.device.destroyBuffer(self.vertices[i], null);
                vc.device.freeMemory(self.vertices_memory[i], null);

                vc.device.destroyBuffer(self.indices[i], null);
                vc.device.freeMemory(self.indices_memory[i], null);
            }

            vc.device.destroyBuffer(self.mesh_info, null);
            vc.device.freeMemory(self.mesh_info_memory, null);
        }
    };
}