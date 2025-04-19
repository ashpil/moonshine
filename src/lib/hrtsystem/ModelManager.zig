const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;

const MeshManager = @import("./MeshManager.zig");
const MaterialManager = @import("./MaterialManager.zig");

const vector = @import("../vector.zig");
const Mat3 = vector.Mat3(f32);

pub const Model = struct {
    const Host = struct {
        blas_handle: vk.AccelerationStructureKHR,
        blas_buffer: core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }),
        geometry_powers: core.mem.DeviceBuffer(Mat3, .{ .storage_buffer_bit = true, .shader_device_address_bit = true }) = .{},
    };

    pub const Device = extern struct {
        geometry_offset: u32,
        geometry_count: u32,
        geometry_powers: vk.DeviceAddress,
        geometry_powers_size: vk.DeviceSize,
    };
};

pub const Geometry = struct {
    pub const Parameters = struct {
        mesh: MeshManager.Handle,
        material: MaterialManager.Handle,
    };

    pub const Host = struct {
        mesh: MeshManager.Handle,
        material: MaterialManager.Handle,
        triangle_powers: core.mem.DeviceBuffer(Mat3, .{ .storage_buffer_bit = true, .shader_device_address_bit = true }) = .{},
    };

    pub const Device = extern struct {
        mesh: MeshManager.Handle,
        material: MaterialManager.Handle,
        triangle_powers: vk.DeviceAddress,
        triangle_powers_size: vk.DeviceSize,
    };
};

const TrianglePowerPipeline = engine.core.pipeline.Pipeline(.{.shader_path = "hrtsystem/local_light/triangle_power.hlsl",
    .local_size = vk.Extent3D { .width = 32, .height = 1, .depth = 1 },
    .PushConstants = extern struct {
        mesh: MeshManager.Handle,
        material: MaterialManager.Handle,
        triangle_count: u32,
        dst_offset: u32,
    },
    .PushSetBindings = struct {
        meshes: core.mem.BufferSlice(MeshManager.Mesh.Device),
        materials: core.mem.BufferSlice(MaterialManager.Material.Device),
        dst_power: core.mem.BufferSlice(Mat3),
    },
    .additional_descriptor_layout_count = 1,
});

const GeometryPowerPipeline = engine.core.pipeline.Pipeline(.{ .shader_path = "hrtsystem/local_light/geometry_power.hlsl",
    .local_size = vk.Extent3D { .width = 32, .height = 1, .depth = 1 },
    .PushConstants = extern struct {
        geometry_count: u32,
        src_offset: u32,
        dst_offset: u32,
    },
    .PushSetBindings = struct {
        geometries: core.mem.BufferSlice(Geometry.Device),
        dst_power: core.mem.BufferSlice(Mat3),
    },
});

const PowerFoldPipeline = engine.core.pipeline.Pipeline(.{ .shader_path = "hrtsystem/local_light/fold3.hlsl",
    .local_size = vk.Extent3D { .width = 32, .height = 1, .depth = 1 },
    .PushConstants = extern struct {
        src_level_offset: u32,
        dst_level_offset: u32,
        max_src_index: u32,
    },
    .PushSetBindings = struct {
        levels: core.mem.BufferSlice(Mat3),
    },
});

const max_geometries = std.math.powi(u32, 2, 12) catch unreachable;
const max_models = std.math.powi(u32, 2, 12) catch unreachable;

triangle_power_pipeline: TrianglePowerPipeline,
geometry_power_pipeline: GeometryPowerPipeline,
power_fold_pipeline: PowerFoldPipeline,

// flat jagged array for geometries --
// use offset + geometry index here to get geometry
// TODO: should separate out geometries to GeometryManager so they can be instanced
geometries_host: std.MultiArrayList(Geometry.Host) = .{},
geometries_device: core.mem.DeviceBuffer(Geometry.Device, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }) = .{},

models_host: std.MultiArrayList(Model.Host) = .{},
models_device: core.mem.DeviceBuffer(Model.Device, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }) = .{},

pub const Handle = u24;

const Self = @This();

pub fn createEmpty(vc: *const VulkanContext, allocator: std.mem.Allocator, texture_descriptor_layout: MaterialManager.TextureManager.DescriptorLayout) !Self {
    var triangle_power_pipeline = try TrianglePowerPipeline.create(vc, allocator, .{}, .{}, .{ texture_descriptor_layout.handle });
    errdefer triangle_power_pipeline.destroy(vc);

    var geometry_power_pipeline = try GeometryPowerPipeline.create(vc, allocator, .{}, .{}, .{});
    errdefer geometry_power_pipeline.destroy(vc);

    var power_fold_pipeline = try PowerFoldPipeline.create(vc, allocator, .{}, .{}, .{});
    errdefer power_fold_pipeline.destroy(vc);

    return Self {
        .triangle_power_pipeline = triangle_power_pipeline,
        .geometry_power_pipeline = geometry_power_pipeline,
        .power_fold_pipeline = power_fold_pipeline,
    };
}

fn powersHierarchySize(base_count: anytype) @TypeOf(base_count) {
    const top_level_size = if (base_count > 1) base_count + (base_count % 2) else 1;
    const other_levels_size = std.math.ceilPowerOfTwoAssert(@TypeOf(base_count), top_level_size) - 1;
    return top_level_size + other_levels_size;
}

// TODO: this really shouldn't have any barriers inside of it as we'd like building individual models to be fully parallelizable
pub fn upload(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, mesh_manager: MeshManager, material_manager: MaterialManager, geometries: []const Geometry.Parameters) !Handle {
    std.debug.assert(self.geometries_host.len + geometries.len <= max_geometries);
    std.debug.assert(self.models_host.len < max_models);

    // TODO: these barriers should probably be elsewhere
    for (geometries) |geometry| {
        encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
            Encoder.BufferBarrier {
                .src_stage_mask = .{ .all_commands_bit = true },
                .src_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true },
                .buffer = mesh_manager.host.items(.position_buffer)[geometry.mesh].handle,
            },
            Encoder.BufferBarrier {
                .src_stage_mask = .{ .all_commands_bit = true },
                .src_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true },
                .buffer = mesh_manager.host.items(.index_buffer)[geometry.mesh].handle,
            },
            Encoder.BufferBarrier {
                .src_stage_mask = .{ .all_commands_bit = true },
                .src_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true },
                .buffer = mesh_manager.device.handle,
            },
            Encoder.BufferBarrier {
                .src_stage_mask = .{ .all_commands_bit = true },
                .src_access_mask = .{ .memory_write_bit = true, .memory_read_bit = true },
                .dst_stage_mask = .{ .all_commands_bit = true },
                .dst_access_mask = .{ .memory_read_bit = true },
                .buffer = material_manager.materials.handle,
            },
        });
    }

    const vk_geometries = try allocator.alloc(vk.AccelerationStructureGeometryKHR, geometries.len);
    defer allocator.free(vk_geometries);

    const primitive_counts = try allocator.alloc(u32, geometries.len);
    defer allocator.free(primitive_counts);

    const build_infos = try allocator.alloc(vk.AccelerationStructureBuildRangeInfoKHR, geometries.len);
    defer allocator.free(build_infos);

    try self.geometries_host.ensureUnusedCapacity(allocator, geometries.len);

    self.triangle_power_pipeline.recordBindPipeline(encoder.buffer);
    self.triangle_power_pipeline.recordBindAdditionalDescriptorSets(encoder.buffer, .{ material_manager.textures.descriptor_set });
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

        const triangle_powers_size = powersHierarchySize(mesh.triangleCount());
        const host = Geometry.Host {
            .material = geometry.material,
            .mesh = geometry.mesh,
            // TODO: should be able to avoid allocating this for meshes that are nowhere emissive
            .triangle_powers = try core.mem.DeviceBuffer(Mat3, .{ .storage_buffer_bit = true, .shader_device_address_bit = true }).create(vc, triangle_powers_size, "triangle powers"),
        };
        errdefer host.triangle_powers.destroy(vc);
        self.geometries_host.appendAssumeCapacity(host);

        primitive_count.* = mesh.triangleCount();
        build_info.* = vk.AccelerationStructureBuildRangeInfoKHR {
            .primitive_count = mesh.triangleCount(),
            .primitive_offset = 0,
            .transform_offset = 0,
            .first_vertex = 0,
        };

        const last_level_size = if (mesh.triangleCount() > 1) mesh.triangleCount() + (mesh.triangleCount() % 2) else 1;

        self.triangle_power_pipeline.recordPushDescriptors(encoder.buffer, .{
            .meshes = mesh_manager.device.deviceSlice(),
            .materials = material_manager.materials.deviceSlice(),
            .dst_power = host.triangle_powers.deviceSlice(),
        });
        self.triangle_power_pipeline.recordPushConstants(encoder.buffer, .{
            .mesh = geometry.mesh,
            .material = geometry.material,
            .triangle_count = primitive_count.*,
            .dst_offset = triangle_powers_size - last_level_size,
        });
        self.triangle_power_pipeline.recordDispatchThreads(encoder.buffer, .{ .width = last_level_size, .height = 1, .depth = 1 });
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
    try encoder.attachResource(scratch_buffer); // TODO: share scratch buffers
    build_geometry_info.scratch_data.device_address = scratch_buffer.getAddress(vc);

    const blas_buffer = try core.mem.DeviceBuffer(u8, .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true }).create(vc, size_info.acceleration_structure_size, "blas buffer");
    errdefer blas_buffer.destroy(vc);

    build_geometry_info.dst_acceleration_structure = try vc.device.createAccelerationStructureKHR(&.{
        .buffer = blas_buffer.handle,
        .offset = 0,
        .size = size_info.acceleration_structure_size,
        .type = .bottom_level_khr,
    }, null);
    errdefer vc.device.destroyAccelerationStructureKHR(build_geometry_info.dst_acceleration_structure, null);

    encoder.buildAccelerationStructures(&.{ build_geometry_info }, &.{ build_infos.ptr });

    self.power_fold_pipeline.recordBindPipeline(encoder.buffer);
    const max_triangle_count = blk: {
        var max_triangle_count: u32 = 0;
        for (geometries) |geometry| {
            max_triangle_count = @max(max_triangle_count, mesh_manager.host.get(geometry.mesh).triangleCount());
        }
        break :blk max_triangle_count;
    };

    const level_count = std.math.log2_int_ceil(u32, max_triangle_count) + 1;
    for (1..level_count) |src_level_rev| {
        const src_level: u32 = @intCast(level_count - src_level_rev);
        for (0..geometries.len) |i| {
            const geometry = self.geometries_host.get(self.geometries_host.len - geometries.len + i);
            const triangle_count = mesh_manager.host.get(geometry.mesh).triangleCount();
            const geometry_level_count = std.math.log2_int_ceil(u32, triangle_count) + 1;
            if (src_level < geometry_level_count) {
                encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
                    Encoder.BufferBarrier {
                        .src_stage_mask = .{ .compute_shader_bit = true },
                        .src_access_mask = .{ .shader_write_bit = true },
                        .dst_stage_mask = .{ .compute_shader_bit = true },
                        .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
                        .buffer = geometry.triangle_powers.handle,
                    },
                });
            }
        }
        for (0..geometries.len) |i| {
            const geometry = self.geometries_host.get(self.geometries_host.len - geometries.len + i);
            const triangle_count = mesh_manager.host.get(geometry.mesh).triangleCount();
            const geometry_level_count = std.math.log2_int_ceil(u32, triangle_count) + 1;
            if (src_level < geometry_level_count) {
                self.power_fold_pipeline.recordPushDescriptors(encoder.buffer, .{
                    .levels = geometry.triangle_powers.deviceSlice(),
                });
                self.power_fold_pipeline.recordPushConstants(encoder.buffer, .{
                    .src_level_offset = std.math.pow(u32, 2, src_level - 0) - 1,
                    .dst_level_offset = std.math.pow(u32, 2, src_level - 1) - 1,
                    .max_src_index = triangle_count,
                });
                const dst_level_size = std.math.pow(u32, 2, src_level);
                self.power_fold_pipeline.recordDispatchThreads(encoder.buffer, .{ .width = dst_level_size, .height = 1, .depth = 1 });
            }
        }
    }

    if (self.geometries_device.isNull()) self.geometries_device = try core.mem.DeviceBuffer(Geometry.Device, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, max_geometries, "geometries");
    for (geometries, 0..) |parameters, i| {
        const geometry = self.geometries_host.get(self.geometries_host.len - geometries.len + i);
        const device = Geometry.Device {
            .material = parameters.material,
            .mesh = parameters.mesh,
            .triangle_powers = geometry.triangle_powers.getAddress(vc),
            .triangle_powers_size = powersHierarchySize(mesh_manager.host.get(geometry.mesh).triangleCount()),
        };
        self.geometries_device.updateFrom(encoder, self.geometries_host.len - geometries.len + i, &.{ device });
    }

    encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .buffer = self.geometries_device.handle,
        },
    });

    const geometry_powers_size = powersHierarchySize(geometries.len);
    const geometry_powers_last_level_size = if (geometries.len > 1) geometries.len + (geometries.len % 2) else 1;
    const geometry_powers_level_count = std.math.log2_int_ceil(usize, geometries.len) + 1;

    const model = Model.Host {
        .blas_handle = build_geometry_info.dst_acceleration_structure,
        .blas_buffer = blas_buffer,
        // TODO: should be able to avoid allocating this for models that are nowhere emissive
        .geometry_powers = try core.mem.DeviceBuffer(Mat3, .{ .storage_buffer_bit = true, .shader_device_address_bit = true }).create(vc, geometry_powers_size, "geometry powers"),
    };

    {
        self.geometry_power_pipeline.recordBindPipeline(encoder.buffer);
        self.geometry_power_pipeline.recordPushDescriptors(encoder.buffer, .{
            .geometries = self.geometries_device.deviceSlice(),
            .dst_power = model.geometry_powers.deviceSlice(),
        });
        self.geometry_power_pipeline.recordPushConstants(encoder.buffer, .{
            .src_offset = @intCast(self.geometries_host.len - geometries.len),
            .geometry_count = @intCast(geometries.len),
            .dst_offset = @intCast(geometry_powers_size - geometry_powers_last_level_size),
        });
        self.geometry_power_pipeline.recordDispatchThreads(encoder.buffer, .{ .width = @intCast(geometry_powers_last_level_size), .height = 1, .depth = 1 });
    }

    if (geometry_powers_last_level_size > 1) {
        encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
            Encoder.BufferBarrier {
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .buffer = self.geometries_device.handle,
            },
        });
    }
    self.power_fold_pipeline.recordBindPipeline(encoder.buffer);
    for (1..geometry_powers_level_count) |src_level_rev| {
        const src_level: u32 = @intCast(geometry_powers_level_count - src_level_rev);
        encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
            Encoder.BufferBarrier {
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true, .shader_write_bit = true },
                .buffer = model.geometry_powers.handle,
            },
        });
        self.power_fold_pipeline.recordPushDescriptors(encoder.buffer, .{
            .levels = model.geometry_powers.deviceSlice(),
        });
        self.power_fold_pipeline.recordPushConstants(encoder.buffer, .{
            .src_level_offset = std.math.pow(u32, 2, src_level - 0) - 1,
            .dst_level_offset = std.math.pow(u32, 2, src_level - 1) - 1,
            .max_src_index = @intCast(geometries.len),
        });
        const dst_level_size = std.math.pow(u32, 2, src_level);
        self.power_fold_pipeline.recordDispatchThreads(encoder.buffer, .{ .width = dst_level_size, .height = 1, .depth = 1 });
    }

    encoder.barrier(&.{}, &[_]Encoder.BufferBarrier{
        Encoder.BufferBarrier {
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .buffer = model.geometry_powers.handle,
        },
    });

    if (self.models_device.isNull()) self.models_device = try core.mem.DeviceBuffer(Model.Device, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }).create(vc, max_models, "models");
    self.models_device.updateFrom(encoder, self.models_host.len, &.{
        Model.Device {
            .geometry_offset = @intCast(self.geometries_host.len - geometries.len),
            .geometry_count = @intCast(geometries.len),
            .geometry_powers = model.geometry_powers.getAddress(vc),
            .geometry_powers_size = geometry_powers_size,
        }
    });

    try self.models_host.append(allocator, model);

    return @intCast(self.models_host.len - 1);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.power_fold_pipeline.destroy(vc);
    self.geometry_power_pipeline.destroy(vc);
    self.triangle_power_pipeline.destroy(vc);
    self.geometries_device.destroy(vc);
    self.models_device.destroy(vc);
    for (self.models_host.items(.blas_handle)) |handle| {
        vc.device.destroyAccelerationStructureKHR(handle, null);
    }
    for (self.models_host.items(.blas_buffer)) |buffer| {
        buffer.destroy(vc);
    }
    for (self.models_host.items(.geometry_powers)) |buffer| {
        buffer.destroy(vc);
    }
    self.models_host.deinit(allocator);
    for (self.geometries_host.items(.triangle_powers)) |buffer| {
        buffer.destroy(vc);
    }
    self.geometries_host.deinit(allocator);
}

// probably bad idea if you're changing many
// TODO: probably no reason to have an abstraction for this here, should just be done properly at point of use
pub fn recordUpdateSingleMaterial(self: Self, command_buffer: VulkanContext.CommandBuffer, geometry_idx: u32, new_material: MaterialManager.Handle) void {
    const offset = @sizeOf(Geometry.Device) * geometry_idx + @offsetOf(Geometry.Device, "material");
    const size = @sizeOf(u32);
    command_buffer.updateBuffer(self.geometries_device.handle, offset, size, &new_material);
    command_buffer.pipelineBarrier2(&vk.DependencyInfo {
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = @ptrCast(&vk.BufferMemoryBarrier2 {
            .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .buffer = self.geometries_device.handle,
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