const std = @import("std");
const vk = @import("vulkan");

const engine = @import("engine");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Commands = core.Commands;
const VkAllocator = core.Allocator;

const hrtsystem = engine.hrtsystem;
const Scene = hrtsystem.Scene;
const World = hrtsystem.World;
const Camera = hrtsystem.Camera;
const Background = hrtsystem.BackgroundManager;
const MeshManager = hrtsystem.MeshManager;
const MaterialManager = hrtsystem.MaterialManager;
const TextureManager = MaterialManager.TextureManager;
const Accel = hrtsystem.Accel;
const Pipeline = hrtsystem.pipeline.StandardPipeline;

const vector = engine.vector;
const F32x2 = vector.Vec2(f32);
const F32x3 = vector.Vec3(f32);
const F32x4 = vector.Vec4(f32);
const U32x3 = vector.Vec3(u32);
const Mat3x4 = vector.Mat3x4(f32);

pub const vulkan_context_device_functions = hrtsystem.required_device_functions;

const Allocator = std.heap.GeneralPurposeAllocator(.{});

comptime {
    _ = HdMoonshine;
}

pub const Material = extern struct {
    normal: TextureManager.Handle,
    emissive: TextureManager.Handle,
    standard_pbr: MaterialManager.StandardPBR,
};

pub const TextureFormat = enum(c_int) {
    f16x4,
    u8x4_srgb,

    fn toVk(self: TextureFormat) vk.Format {
        switch (self) {
            .f16x4 => return .r16g16b16a16_sfloat,
            .u8x4_srgb => return .r8g8b8a8_srgb,
        }
    }

    fn pixelSizeInBytes(self: TextureFormat) usize {
        switch (self) {
            .f16x4 => return @sizeOf(f16) * 4,
            .u8x4_srgb => return @sizeOf(u8) * 4,
        }
    }
};

pub const HdMoonshine = struct {
    allocator: Allocator,
    vk_allocator: VkAllocator,
    vc: VulkanContext,
    commands: Commands,

    world: World,
    camera: Camera,
    background: Background,

    pipeline: Pipeline,

    output_buffers: std.ArrayListUnmanaged(VkAllocator.HostBuffer([4]f32)),

    // as a temporary hack, while the resource system is not yet streamlined,
    // force it to all be singlethreaded
    mutex: std.Thread.Mutex,

    material_updates: std.AutoArrayHashMapUnmanaged(MaterialManager.Handle, MaterialUpdate),

    // only keep a single bit for deciding if we should update all --
    // could technically be more granular
    need_instance_update: bool,

    const MaterialUpdate = struct {
        normal: ?TextureManager.Handle = null,
        emissive: ?TextureManager.Handle = null,
        color: ?TextureManager.Handle = null,
        metalness: ?TextureManager.Handle = null,
        roughness: ?TextureManager.Handle = null,
        ior: ?f32 = null,
    };

    const samples_per_run = 1;

    pub export fn HdMoonshineCreate() ?*HdMoonshine {
        var allocator = Allocator {};
        errdefer _ = allocator.deinit();

        const self = allocator.allocator().create(HdMoonshine) catch return null;
        errdefer allocator.allocator().destroy(self);

        self.allocator = allocator;
        self.vc = VulkanContext.create(self.allocator.allocator(), "hdMoonshine", &.{}, &hrtsystem.required_device_extensions, &hrtsystem.required_device_features, null) catch return null;
        errdefer self.vc.destroy();

        self.commands = Commands.create(&self.vc) catch return null;
        errdefer self.commands.destroy(&self.vc);

        self.vk_allocator = VkAllocator.create(&self.vc, self.allocator.allocator()) catch return null;
        errdefer self.vk_allocator.destroy(&self.vc, self.allocator.allocator());

        self.world = World.createEmpty(&self.vc) catch return null;
        errdefer self.world.destroy(&self.vc, self.allocator.allocator());

        self.camera = Camera {};
        errdefer self.camera.destroy(&self.vc, self.allocator.allocator());

        self.background = Background.create(&self.vc) catch return null;
        errdefer self.background.destroy(&self.vc, self.allocator.allocator());
        self.background.addDefaultBackground(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands) catch return null;

        self.pipeline = Pipeline.create(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, self.world.materials.textures.descriptor_layout, .{
            .samples_per_run = samples_per_run,
            .max_bounces = 1024,
            .env_samples_per_bounce = 0,
            .mesh_samples_per_bounce = 0,
            .flip_image = false,
            .indexed_attributes = false,
        }, .{ self.background.sampler }) catch return null;
        errdefer self.pipeline.destroy(&self.vc);

        self.output_buffers = .{};
        self.mutex = .{};
        self.material_updates = .{};
        self.need_instance_update = false;

        return self;
    }

    pub export fn HdMoonshineRender(self: *HdMoonshine, sensor: Camera.SensorHandle, lens: Camera.LensHandle) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.commands.startRecording(&self.vc) catch return false;

        // update instance transforms
        {   
            if (self.material_updates.count() != 0) {
                var iter = self.material_updates.iterator();
                while (iter.next()) |update| {
                    // since only standard pbr materials are supported 
                    // the material index and variant index should be identical
                    const index = update.key_ptr.*;

                    // TODO: can merge some of these cmdUpdateBuffers sometimes
                    if (update.value_ptr.normal) |normal| {
                        const offset = index * @sizeOf(MaterialManager.Material) + @offsetOf(MaterialManager.Material, "normal");
                        const bytes = std.mem.asBytes(&normal);
                        self.vc.device.cmdUpdateBuffer(self.commands.buffer, self.world.materials.materials.handle, offset, bytes.len, bytes.ptr);
                    }
                    if (update.value_ptr.emissive) |emissive| {
                        const offset = index * @sizeOf(MaterialManager.Material) + @offsetOf(MaterialManager.Material, "emissive");
                        const bytes = std.mem.asBytes(&emissive);
                        self.vc.device.cmdUpdateBuffer(self.commands.buffer, self.world.materials.materials.handle, offset, bytes.len, bytes.ptr);
                    }
                    if (update.value_ptr.color) |color| {
                        const offset = index * @sizeOf(MaterialManager.StandardPBR) + @offsetOf(MaterialManager.StandardPBR, "color");
                        const bytes = std.mem.asBytes(&color);
                        self.vc.device.cmdUpdateBuffer(self.commands.buffer, self.world.materials.variant_buffers.standard_pbr.buffer.handle, offset, bytes.len, bytes.ptr);
                    }
                    if (update.value_ptr.metalness) |metalness| {
                        const offset = index * @sizeOf(MaterialManager.StandardPBR) + @offsetOf(MaterialManager.StandardPBR, "metalness");
                        const bytes = std.mem.asBytes(&metalness);
                        self.vc.device.cmdUpdateBuffer(self.commands.buffer, self.world.materials.variant_buffers.standard_pbr.buffer.handle, offset, bytes.len, bytes.ptr);
                    }
                    if (update.value_ptr.roughness) |roughness| {
                        const offset = index * @sizeOf(MaterialManager.StandardPBR) + @offsetOf(MaterialManager.StandardPBR, "roughness");
                        const bytes = std.mem.asBytes(&roughness);
                        self.vc.device.cmdUpdateBuffer(self.commands.buffer, self.world.materials.variant_buffers.standard_pbr.buffer.handle, offset, bytes.len, bytes.ptr);
                    }
                    if (update.value_ptr.ior) |ior| {
                        const offset = index * @sizeOf(MaterialManager.StandardPBR) + @offsetOf(MaterialManager.StandardPBR, "ior");
                        const bytes = std.mem.asBytes(&ior);
                        self.vc.device.cmdUpdateBuffer(self.commands.buffer, self.world.materials.variant_buffers.standard_pbr.buffer.handle, offset, bytes.len, bytes.ptr);
                    }
                }

                // could be more granular with this and instance updates below
                const update_barriers = [_]vk.BufferMemoryBarrier2 {
                    .{
                        .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
                        .src_access_mask = .{ .transfer_write_bit = true },
                        .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                        .dst_access_mask = .{ .shader_storage_read_bit = true },
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .buffer = self.world.materials.materials.handle,
                        .offset = 0,
                        .size = vk.WHOLE_SIZE,
                    },
                    .{
                        .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
                        .src_access_mask = .{ .transfer_write_bit = true },
                        .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                        .dst_access_mask = .{ .shader_storage_read_bit = true },
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .buffer = self.world.materials.variant_buffers.standard_pbr.buffer.handle,
                        .offset = 0,
                        .size = vk.WHOLE_SIZE,
                    },
                };
                self.vc.device.cmdPipelineBarrier2(self.commands.buffer, &vk.DependencyInfo {
                    .buffer_memory_barrier_count = update_barriers.len,
                    .p_buffer_memory_barriers = &update_barriers,
                });

                self.material_updates.clearRetainingCapacity();
            }

            if (self.need_instance_update) {
                var actual_size_instances = self.world.accel.instances_host;
                actual_size_instances.data.len = self.world.accel.instance_count;
                var actual_size_world_to_instance = self.world.accel.world_to_instance_host;
                actual_size_world_to_instance.data.len = self.world.accel.instance_count;
                self.commands.recordUploadBuffer(vk.AccelerationStructureInstanceKHR, &self.vc, self.world.accel.instances_device, actual_size_instances);
                self.commands.recordUploadBuffer(Mat3x4, &self.vc, self.world.accel.world_to_instance_device, actual_size_world_to_instance);

                const update_barriers = [_]vk.BufferMemoryBarrier2 {
                    .{
                        .src_stage_mask = .{ .copy_bit = true },
                        .src_access_mask = .{ .transfer_write_bit = true },
                        .dst_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
                        .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true, .shader_storage_read_bit = true },
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .buffer = self.world.accel.instances_device.handle,
                        .offset = 0,
                        .size = vk.WHOLE_SIZE,
                    },
                    .{
                        .src_stage_mask = .{ .copy_bit = true },
                        .src_access_mask = .{ .transfer_write_bit = true },
                        .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                        .dst_access_mask = .{ .shader_storage_read_bit = true },
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .buffer = self.world.accel.world_to_instance_device.handle,
                        .offset = 0,
                        .size = vk.WHOLE_SIZE,
                    },
                };
                self.vc.device.cmdPipelineBarrier2(self.commands.buffer, &vk.DependencyInfo {
                    .buffer_memory_barrier_count = update_barriers.len,
                    .p_buffer_memory_barriers = &update_barriers,
                });

                const geometry = vk.AccelerationStructureGeometryKHR {
                    .geometry_type = .instances_khr,
                    .flags = .{ .opaque_bit_khr = true },
                    .geometry = .{
                        .instances = .{
                            .array_of_pointers = vk.FALSE,
                            .data = .{
                                .device_address = self.world.accel.instances_address,
                            }
                        }
                    },
                };

                var geometry_info = vk.AccelerationStructureBuildGeometryInfoKHR {
                    .type = .top_level_khr,
                    .flags = .{ .prefer_fast_trace_bit_khr = true, .allow_update_bit_khr = true },
                    .mode = .update_khr,
                    .src_acceleration_structure = self.world.accel.tlas_handle,
                    .dst_acceleration_structure = self.world.accel.tlas_handle,
                    .geometry_count = 1,
                    .p_geometries = @ptrCast(&geometry),
                    .scratch_data = .{
                        .device_address = self.world.accel.tlas_update_scratch_address,
                    },
                };

                const build_info = vk.AccelerationStructureBuildRangeInfoKHR {
                    .primitive_count = self.world.accel.instance_count,
                    .first_vertex = 0,
                    .primitive_offset = 0,
                    .transform_offset = 0,
                };

                const build_info_ref = &build_info;

                self.vc.device.cmdBuildAccelerationStructuresKHR(self.commands.buffer, 1, @ptrCast(&geometry_info), @ptrCast(&build_info_ref));

                const ray_trace_barriers = [_]vk.MemoryBarrier2 {
                    .{
                        .src_stage_mask = .{ .acceleration_structure_build_bit_khr = true },
                        .src_access_mask = .{ .acceleration_structure_write_bit_khr = true },
                        .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                        .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true },
                    }
                };
                self.vc.device.cmdPipelineBarrier2(self.commands.buffer, &vk.DependencyInfo {
                    .memory_barrier_count = ray_trace_barriers.len,
                    .p_memory_barriers = &ray_trace_barriers,
                });
            }

            self.need_instance_update = false;
        }

        // prepare our stuff
        self.camera.sensors.items[sensor].recordPrepareForCapture(&self.vc, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true }, .{});

        // bind our stuff
        self.pipeline.recordBindPipeline(&self.vc, self.commands.buffer);
        self.pipeline.recordBindTextureDescriptorSet(&self.vc, self.commands.buffer, self.world.materials.textures.descriptor_set);
        self.pipeline.recordPushDescriptors(&self.vc, self.commands.buffer, (Scene { .background = self.background, .camera = self.camera, .world = self.world }).pushDescriptors(sensor, 0));

        // push our stuff
        const bytes = std.mem.asBytes(&.{ self.camera.lenses.items[lens], self.camera.sensors.items[sensor].sample_count });
        self.vc.device.cmdPushConstants(self.commands.buffer, self.pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

        // trace our stuff
        self.pipeline.recordTraceRays(&self.vc, self.commands.buffer, self.camera.sensors.items[sensor].extent);

        // copy our stuff
        self.camera.sensors.items[sensor].recordPrepareForCopy(&self.vc, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true }, .{ .copy_bit = true });

        // copy rendered image to host-visible staging buffer
        const copy = vk.BufferImageCopy {
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{
                .x = 0,
                .y = 0,
                .z = 0,
            },
            .image_extent = .{
                .width = self.camera.sensors.items[sensor].extent.width,
                .height = self.camera.sensors.items[sensor].extent.height,
                .depth = 1,
            },
        };
        self.vc.device.cmdCopyImageToBuffer(self.commands.buffer, self.camera.sensors.items[sensor].image.handle, .transfer_src_optimal, self.output_buffers.items[sensor].handle, 1, @ptrCast(&copy));

        self.commands.submitAndIdleUntilDone(&self.vc) catch return false;

        self.camera.sensors.items[sensor].sample_count += samples_per_run;

        return true;
    }

    pub export fn HdMoonshineRebuildPipeline(self: *HdMoonshine) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const old_pipeline = self.pipeline.recreate(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, .{
            .samples_per_run = samples_per_run,
            .max_bounces = 1024,
            .env_samples_per_bounce = 0,
            .mesh_samples_per_bounce = 0,
            .flip_image = false,
            .indexed_attributes = false,
        }) catch return false;
        self.vc.device.destroyPipeline(old_pipeline, null);
        self.camera.clearAllSensors();
        return true;
    }

    pub export fn HdMoonshineCreateMesh(self: *HdMoonshine, positions: [*]const F32x3, maybe_normals: ?[*]const F32x3, maybe_texcoords: ?[*]const F32x2, position_count: usize, indices: [*]const U32x3, index_count: usize) MeshManager.Handle {
        self.mutex.lock();
        defer self.mutex.unlock();
        const mesh = MeshManager.Mesh {
            .positions = positions[0..position_count],
            .normals = if (maybe_normals) |normals| normals[0..index_count * 3] else null,
            .texcoords = if (maybe_texcoords) |texcoords| texcoords[0..index_count * 3] else null,
            .indices = indices[0..index_count],
        };
        return self.world.meshes.upload(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, mesh) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineCreateSolidTexture1(self: *HdMoonshine, source: f32, name: [*:0]const u8) TextureManager.Handle {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.world.materials.textures.upload(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, TextureManager.Source {
            .f32x1 = source,
        }, std.mem.span(name)) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineCreateSolidTexture2(self: *HdMoonshine, source: F32x2, name: [*:0]const u8) TextureManager.Handle {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.world.materials.textures.upload(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, TextureManager.Source {
            .f32x2 = source,
        }, std.mem.span(name)) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineCreateSolidTexture3(self: *HdMoonshine, source: F32x3, name: [*:0]const u8) TextureManager.Handle {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.world.materials.textures.upload(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, TextureManager.Source {
            .f32x3 = source,
        }, std.mem.span(name)) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineCreateRawTexture(self: *HdMoonshine, data: [*]u8, extent: vk.Extent2D, format: TextureFormat, name: [*:0]const u8) TextureManager.Handle {
        self.mutex.lock();
        defer self.mutex.unlock();
        const bytes = std.mem.sliceAsBytes(data[0..extent.width * extent.height * format.pixelSizeInBytes()]);
        return self.world.materials.textures.upload(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, TextureManager.Source {
            .raw = TextureManager.Source.Raw {
                .bytes = bytes,
                .extent = extent,
                .format = format.toVk(),
            },
        }, std.mem.span(name)) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineCreateMaterial(self: *HdMoonshine, material: Material) MaterialManager.Handle {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.world.materials.upload(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, MaterialManager.MaterialInfo {
            .normal = material.normal,
            .emissive = material.emissive,
            .variant = MaterialManager.MaterialVariant {
                .standard_pbr = material.standard_pbr,
            },
        }) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineSetMaterialNormal(self: *HdMoonshine, material: MaterialManager.Handle, image: TextureManager.Handle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.material_updates.getOrPut(self.allocator.allocator(), material) catch unreachable; // TODO: error handling
        if (!result.found_existing) result.value_ptr.* = .{};
        result.value_ptr.normal = image;
    }

    pub export fn HdMoonshineSetMaterialEmissive(self: *HdMoonshine, material: MaterialManager.Handle, image: TextureManager.Handle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.material_updates.getOrPut(self.allocator.allocator(), material) catch unreachable; // TODO: error handling
        if (!result.found_existing) result.value_ptr.* = .{};
        result.value_ptr.emissive = image;
    }

    pub export fn HdMoonshineSetMaterialColor(self: *HdMoonshine, material: MaterialManager.Handle, image: TextureManager.Handle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.material_updates.getOrPut(self.allocator.allocator(), material) catch unreachable; // TODO: error handling
        if (!result.found_existing) result.value_ptr.* = .{};
        result.value_ptr.color = image;
    }

    pub export fn HdMoonshineSetMaterialMetalness(self: *HdMoonshine, material: MaterialManager.Handle, image: TextureManager.Handle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.material_updates.getOrPut(self.allocator.allocator(), material) catch unreachable; // TODO: error handling
        if (!result.found_existing) result.value_ptr.* = .{};
        result.value_ptr.metalness = image;
    }

    pub export fn HdMoonshineSetMaterialRoughness(self: *HdMoonshine, material: MaterialManager.Handle, image: TextureManager.Handle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.material_updates.getOrPut(self.allocator.allocator(), material) catch unreachable; // TODO: error handling
        if (!result.found_existing) result.value_ptr.* = .{};
        result.value_ptr.roughness = image;
    }

    pub export fn HdMoonshineSetMaterialIOR(self: *HdMoonshine, material: MaterialManager.Handle, ior: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.material_updates.getOrPut(self.allocator.allocator(), material) catch unreachable; // TODO: error handling
        if (!result.found_existing) result.value_ptr.* = .{};
        result.value_ptr.ior = ior;
    }

    pub export fn HdMoonshineCreateInstance(self: *HdMoonshine, transform: Mat3x4, geometries: [*]const Accel.Geometry, geometry_count: usize, visible: bool) Accel.Handle {
        self.mutex.lock();
        defer self.mutex.unlock();
        const instance = Accel.Instance {
            .transform = transform,
            .visible = visible,
            .geometries = geometries[0..geometry_count],
        };
        self.camera.clearAllSensors();
        return self.world.accel.uploadInstance(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, self.world.meshes, instance) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineDestroyInstance(self: *HdMoonshine, handle: Accel.Handle) void {
        HdMoonshineSetInstanceVisibility(self, handle, false); // sike. TODO: proper destruction
    }

    pub export fn HdMoonshineSetInstanceVisibility(self: *HdMoonshine, handle: Accel.Handle, visible: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.world.accel.instances_host.data[handle].instance_custom_index_and_mask.mask = if (visible) 0xFF else 0x00;
        self.need_instance_update = true;
        self.camera.clearAllSensors();
    }

    pub export fn HdMoonshineSetInstanceTransform(self: *HdMoonshine, handle: Accel.Handle, new_transform: Mat3x4) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.world.accel.instances_host.data[handle].transform = @bitCast(new_transform);
        self.need_instance_update = true;
        self.camera.clearAllSensors();
    }

    pub export fn HdMoonshineCreateSensor(self: *HdMoonshine, extent: vk.Extent2D) Camera.SensorHandle {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.output_buffers.append(self.allocator.allocator(), self.vk_allocator.createHostBuffer(&self.vc, [4]f32, extent.width * extent.height, .{ .transfer_dst_bit = true }) catch unreachable) catch unreachable;
        return self.camera.appendSensor(&self.vc, &self.vk_allocator, self.allocator.allocator(), extent) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineGetSensorData(self: *const HdMoonshine, sensor: Camera.SensorHandle) [*][4]f32 {
        return self.output_buffers.items[sensor].data.ptr;
    }

    pub export fn HdMoonshineCreateLens(self: *HdMoonshine, info: Camera.Lens) Camera.LensHandle {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.camera.appendLens(self.allocator.allocator(), info) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineSetLens(self: *HdMoonshine, handle: Camera.LensHandle, info: Camera.Lens) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.camera.lenses.items[handle] = info;

        // technically only need to clear sensors associated with this lens
        // but no easy mechanism to do this currently
        self.camera.clearAllSensors();
    }

    pub export fn HdMoonshineDestroy(self: *HdMoonshine) void {
        self.material_updates.deinit(self.allocator.allocator());
        for (self.output_buffers.items) |output_buffer| {
            output_buffer.destroy(&self.vc);
        }
        self.output_buffers.deinit(self.allocator.allocator());
        self.pipeline.destroy(&self.vc);
        self.world.destroy(&self.vc, self.allocator.allocator());
        self.background.destroy(&self.vc, self.allocator.allocator());
        self.camera.destroy(&self.vc, self.allocator.allocator());
        self.commands.destroy(&self.vc);
        self.vk_allocator.destroy(&self.vc, self.allocator.allocator());
        self.vc.destroy();
        var alloc = self.allocator;
        alloc.allocator().destroy(self);
        _ = alloc.deinit();
    }
};

