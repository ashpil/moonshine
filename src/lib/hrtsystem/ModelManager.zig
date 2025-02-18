const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;

const MeshManager = @import("./MeshManager.zig");
const MaterialManager = @import("./MaterialManager.zig");

pub const Geometry = extern struct {
    mesh: MeshManager.Handle,
    material: MaterialManager.Handle,
};

const BottomLevelAccels = std.MultiArrayList(struct {
    handle: vk.AccelerationStructureKHR,
    buffer: core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }),
});

const max_geometries = std.math.powi(u32, 2, 12) catch unreachable;
const max_models = std.math.powi(u32, 2, 12) catch unreachable;

// flat jagged array for geometries --
// use offset + geometry index here to get geometry
geometry_count: u32 = 0,
geometries: core.mem.DeviceBuffer(Geometry, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }) = .{},

blases: BottomLevelAccels = .{},
model_to_geometry_offset: core.mem.DeviceBuffer(u32, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }) = .{},

pub const Handle = u24;

const Self = @This();

pub fn upload(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, mesh_manager: MeshManager, geometries: []const Geometry) !Handle {
    std.debug.assert(self.geometry_count + geometries.len <= max_geometries);
    std.debug.assert(self.blases.len < max_models);

    for (geometries) |geometry| {
        encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
            Encoder.BufferBarrier {
                .src_stage_mask = .{ .all_commands_bit = true },
                .src_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
                .buffer = mesh_manager.host.items(.position_buffer)[geometry.mesh].handle,
            },
            Encoder.BufferBarrier {
                .src_stage_mask = .{ .all_commands_bit = true },
                .src_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
                .buffer = mesh_manager.host.items(.index_buffer)[geometry.mesh].handle,
            },
        });
    }

    const vk_geometries = try allocator.alloc(vk.AccelerationStructureGeometryKHR, geometries.len);
    defer allocator.free(vk_geometries);

    const primitive_counts = try allocator.alloc(u32, geometries.len);
    defer allocator.free(primitive_counts);

    const build_infos = try allocator.alloc(vk.AccelerationStructureBuildRangeInfoKHR, geometries.len);
    defer allocator.free(build_infos);

    for (geometries, vk_geometries, primitive_counts, build_infos) |geometry, *vk_geometry, *primitive_count, *build_info| {
        const mesh = mesh_manager.host.get(geometry.mesh);

        vk_geometry.* = vk.AccelerationStructureGeometryKHR {
            .geometry_type = .triangles_khr,
            .flags = .{ .opaque_bit_khr = true },
            .geometry = .{
                .triangles = .{
                    .vertex_format = .r32g32b32_sfloat,
                    .vertex_data = .{
                        .device_address = mesh.position_buffer.getAddress(vc),
                    },
                    .vertex_stride = @sizeOf(f32) * 3,
                    .max_vertex = @intCast(mesh.vertex_count - 1),
                    .index_type = if (mesh.index_count != 0) .uint32 else .none_khr,
                    .index_data = .{
                        .device_address = mesh.index_buffer.getAddress(vc),
                    },
                    .transform_data = .{
                        .device_address = 0, // TODO: should be able to specify this
                    }
                }
            }
        };

        build_info.* = vk.AccelerationStructureBuildRangeInfoKHR {
            .primitive_count = @intCast(if (mesh.index_count != 0) mesh.index_count else @divExact(mesh.vertex_count, 3)),
            .primitive_offset = 0,
            .transform_offset = 0,
            .first_vertex = 0,
        };
        primitive_count.* = build_info.primitive_count;
    }

    var build_geometry_info = vk.AccelerationStructureBuildGeometryInfoKHR {
        .type = .bottom_level_khr,
        .flags = .{ .prefer_fast_trace_bit_khr = true },
        .mode = .build_khr,
        .geometry_count = @intCast(vk_geometries.len),
        .p_geometries = vk_geometries.ptr,
        .scratch_data = undefined,
    };

    const size_info = getBuildSizesInfo(vc, &build_geometry_info, primitive_counts.ptr);

    const scratch_buffer = try core.mem.DeviceBuffer(u8, .{ .storage_buffer_bit = true, .shader_device_address_bit = true }).create(vc, size_info.build_scratch_size, "blas scratch buffer");
    try encoder.attachResource(scratch_buffer);
    build_geometry_info.scratch_data.device_address = scratch_buffer.getAddress(vc);

    const buffer = try core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }).create(vc, size_info.acceleration_structure_size, "blas buffer");
    errdefer buffer.destroy(vc);

    build_geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(&.{
        .buffer = buffer.handle,
        .offset = 0,
        .size = size_info.acceleration_structure_size,
        .type = .bottom_level_khr,
    }, null);
    errdefer vc.device.destroyAccelerationStructureKHR(build_geometry_info.dst_acceleration_structure, null);

    encoder.buildAccelerationStructures(&.{ build_geometry_info }, &.{ build_infos.ptr });

    if (self.geometries.isNull()) self.geometries = try core.mem.DeviceBuffer(Geometry, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, max_geometries, "geometries");
    self.geometries.updateFrom(encoder, self.geometry_count, geometries);

    if (self.model_to_geometry_offset.isNull()) self.model_to_geometry_offset = try core.mem.DeviceBuffer(u32, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, max_models, "model idx to geometry offset");
    self.model_to_geometry_offset.updateFrom(encoder, self.blases.len, &.{ @intCast(self.geometry_count) });

    self.geometry_count += @intCast(geometries.len);

    try self.blases.append(allocator, .{
        .handle = build_geometry_info.dst_acceleration_structure,
        .buffer = buffer,
    });

    return @intCast(self.blases.len - 1);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.geometries.destroy(vc);
    self.model_to_geometry_offset.destroy(vc);
    for (self.blases.items(.handle)) |handle| {
        vc.device.destroyAccelerationStructureKHR(handle, null);
    }
    for (self.blases.items(.buffer)) |buffer| {
        buffer.destroy(vc);
    }
    self.blases.deinit(allocator);
}

// probably bad idea if you're changing many
// TODO: probably no reason to have an abstraction for this here, should just be done properly at point of use
pub fn recordUpdateSingleMaterial(self: Self, command_buffer: VulkanContext.CommandBuffer, geometry_idx: u32, new_material: MaterialManager.Handle) void {
    const offset = @sizeOf(Geometry) * geometry_idx + @offsetOf(Geometry, "material");
    const size = @sizeOf(u32);
    command_buffer.updateBuffer(self.geometries.handle, offset, size, &new_material);
    command_buffer.pipelineBarrier2(&vk.DependencyInfo {
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = @ptrCast(&vk.BufferMemoryBarrier2 {
            .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = self.geometries.handle,
            .offset = offset,
            .size = size,
        }),
    });
}

fn getBuildSizesInfo(vc: *const VulkanContext, geometry_info: *const vk.AccelerationStructureBuildGeometryInfoKHR, max_primitive_count: [*]const u32) vk.AccelerationStructureBuildSizesInfoKHR {
    var size_info: vk.AccelerationStructureBuildSizesInfoKHR = undefined;
    size_info.s_type = .acceleration_structure_build_sizes_info_khr;
    size_info.p_next = null;
    vc.device.getAccelerationStructureBuildSizesKHR(.device_khr, geometry_info, max_primitive_count, &size_info);
    return size_info;
}