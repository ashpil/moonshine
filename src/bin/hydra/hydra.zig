const std = @import("std");
const vk = @import("vulkan");

const engine = @import("engine");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const vk_helpers = core.vk_helpers;

const hrtsystem = engine.hrtsystem;
const Scene = hrtsystem.Scene;
const World = hrtsystem.World;
const Camera = hrtsystem.CameraManager;
const Background = hrtsystem.BackgroundManager;
const MeshManager = hrtsystem.MeshManager;
const ModelManager = hrtsystem.ModelManager;
const MaterialManager = hrtsystem.MaterialManager;
const TextureManager = MaterialManager.TextureManager;
const Accel = hrtsystem.Accel;
const Pipeline = hrtsystem.pipeline.Render;

const vector = engine.vector;
const F32x2 = vector.Vec2(f32);
const F32x3 = vector.Vec3(f32);
const F32x4 = vector.Vec4(f32);
const Mat3 = vector.Mat3(f32);
const Mat4 = vector.Mat4(f32);
const Mat4x3 = vector.Mat4x3(f32);

comptime {
    _ = HdMoonshine;
}

pub const Material = extern struct {
    normal: TextureManager.Handle,
    emissive: TextureManager.Handle,
    color: TextureManager.Handle,
    metalness: TextureManager.Handle,
    roughness: TextureManager.Handle,
    ior: f32,
};

pub const TextureFormat = enum(c_int) {
    f32x1,
    f32x2,
    f32x4,
    f16x4,
    u8x1,
    u8x2,
    u8x4,
    u8x4_srgb,

    fn toVk(self: TextureFormat) vk.Format {
        switch (self) {
            .f32x1 => return .r32_sfloat,
            .f32x2 => return .r32g32_sfloat,
            .f32x4 => return .r32g32b32a32_sfloat,
            .f16x4 => return .r16g16b16a16_sfloat,
            .u8x1 => return .r8_unorm,
            .u8x2 => return .r8g8_unorm,
            .u8x4 => return .r8g8b8a8_unorm,
            .u8x4_srgb => return .r8g8b8a8_srgb,
        }
    }

    fn pixelSizeInBytes(self: TextureFormat) usize {
        switch (self) {
            .f32x1 => return @sizeOf(f32) * 1,
            .f32x2 => return @sizeOf(f32) * 2,
            .f32x4 => return @sizeOf(f32) * 4,
            .f16x4 => return @sizeOf(f16) * 4,
            .u8x1 => return @sizeOf(u8) * 1,
            .u8x2 => return @sizeOf(u8) * 2,
            .u8x4 => return @sizeOf(u8) * 4,
            .u8x4_srgb => return @sizeOf(u8) * 4,
        }
    }
};

pub const HdMoonshine = struct {
    allocator: engine.Allocator,
    vc: VulkanContext,
    encoder: Encoder,

    world: World,
    camera: Camera,
    background: Background,

    pipeline: Pipeline,

    output_buffers: std.ArrayListUnmanaged(core.mem.DownloadBuffer([4]f32)),

    io_threaded: std.Io.Threaded,
    io: std.Io,

    // as a temporary hack, while the resource system is not yet streamlined,
    // force it to all be singlethreaded
    mutex: std.Io.Mutex,

    materials_dirty: bool,
    instances_dirty: bool,

    frame_index: u32,

    current_background: Background.Handle,

    const pipeline_settings = Pipeline.SpecConstants {
        .path_tracing_env_samples_per_bounce = 1,
        .path_tracing_mesh_samples_per_bounce = 1,
    };

    pub export fn HdMoonshineCreate() ?*HdMoonshine {
        var allocator = engine.Allocator.init();
        errdefer _ = allocator.deinit();

        const self = allocator.allocator().create(HdMoonshine) catch return null;
        errdefer allocator.allocator().destroy(self);

        self.allocator = allocator;

        self.io_threaded = std.Io.Threaded.init(self.allocator.allocator(), .{});
        errdefer self.io_threaded.deinit();
        self.io = self.io_threaded.io();

        self.vc = VulkanContext.create(self.allocator.allocator(), "hdMoonshine", hrtsystem.vulkan_requirements) catch return null;
        errdefer self.vc.destroy(self.allocator.allocator());

        self.encoder = Encoder.create(&self.vc, "main") catch return null;
        errdefer self.encoder.destroy(&self.vc);

        // always keep an encoder open for incoming commands
        self.encoder.begin() catch return null;

        self.world = World.createEmpty(&self.vc, self.allocator.allocator(), &self.encoder) catch return null;
        errdefer self.world.destroy(&self.vc, self.allocator.allocator());

        self.camera = Camera {};
        errdefer self.camera.destroy(&self.vc, self.allocator.allocator());

        self.background = Background.create(&self.vc) catch return null;
        errdefer self.background.destroy(&self.vc, self.allocator.allocator());
        const background_color = [4]f32 { 0.0, 0.0, 0.0, 1.0 };
        const background_staging = self.encoder.uploadAllocator().alignedAlloc(u8, .fromByteUnits(16), @sizeOf(@TypeOf(background_color))) catch return null;
        @memcpy(background_staging, std.mem.asBytes(&background_color));
        self.current_background = self.background.addBackground(&self.vc, self.allocator.allocator(), &self.encoder, self.encoder.upload_allocator.getBufferSlice(background_staging).asBytes(), .{ .width = 1, .height = 1 }, .r32g32b32a32_sfloat, Mat3.identity, "default") catch return null;

        self.pipeline = Pipeline.create(&self.vc, pipeline_settings, .{ self.background.equal_area_sampler }, .{ self.world.materials.textures.descriptor_layout.handle, self.world.constant_spectra.descriptor_layout.handle }) catch return null;
        errdefer self.pipeline.destroy(&self.vc);

        self.output_buffers = .empty;
        self.mutex = .init;
        self.materials_dirty = false;
        self.instances_dirty = false;
        self.frame_index = 0;

        return self;
    }

    pub export fn HdMoonshineRender(self: *HdMoonshine, sensor: Camera.SensorHandle, camera: Camera.CameraHandle) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.materials_dirty) {
            self.encoder.barrier(&.{}, &.{
                .{
                    .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
                    .src_access_mask = .{ .transfer_write_bit = true },
                    .dst_stage_mask = .{ .compute_shader_bit = true },
                    .dst_access_mask = .{ .shader_storage_read_bit = true },
                    .buffer = self.world.materials.materials.handle,
                },
                .{
                    .src_stage_mask = .{ .clear_bit = true }, // cmdUpdateBuffer seems to be clear for some reason
                    .src_access_mask = .{ .transfer_write_bit = true },
                    .dst_stage_mask = .{ .compute_shader_bit = true },
                    .dst_access_mask = .{ .shader_storage_read_bit = true },
                    .buffer = self.world.materials.variant_buffers.standard_pbr.buffer.handle,
                },
            });
            self.materials_dirty = false;
        }

        if (self.instances_dirty) {
            self.world.accel.build(&self.vc, &self.encoder, self.world.models) catch return false;
            self.instances_dirty = false;
        }

        const scene = Scene { .background = self.background, .camera = self.camera, .world = self.world };

        // TODO: this memory barrier is a little more extreme than neccessary
        self.encoder.buffer.pipelineBarrier2(&vk.DependencyInfo {
            .memory_barrier_count = 1,
            .p_memory_barriers = &[1]vk.MemoryBarrier2 {
                .{
                    .src_stage_mask = .{ .compute_shader_bit = true },
                    .src_access_mask = .{ .shader_write_bit = true },
                    .dst_stage_mask = .{ .compute_shader_bit = true },
                    .dst_access_mask = .{ .acceleration_structure_read_bit_khr = true },
                }
            },
        });

        self.encoder.barrier(&[_]Encoder.ImageBarrier {
            Encoder.ImageBarrier {
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = if (self.camera.sensors.items[sensor].sample_count == 0) .{ .shader_storage_write_bit = true } else .{ .shader_storage_write_bit = true, .shader_storage_read_bit = true },
                .old_layout = if (self.camera.sensors.items[sensor].sample_count == 0) .undefined else .general,
                .new_layout = .general,
                .image = self.camera.sensors.items[sensor].image.handle,
            }
        }, &.{});

        // bind our stuff
        self.pipeline.recordBindPipeline(self.encoder.buffer);
        self.pipeline.recordBindAdditionalDescriptorSets(self.encoder.buffer, .{ self.world.materials.textures.descriptor_set, self.world.constant_spectra.descriptor_set });
        self.pipeline.recordPushDescriptors(self.encoder.buffer, scene.pushDescriptors(camera, sensor, self.current_background));

        // push our stuff
        self.pipeline.recordPushConstants(self.encoder.buffer, scene.pushConstants(camera, sensor, self.current_background, self.frame_index));

        // trace our stuff
        self.pipeline.recordDispatchThreads2D(self.encoder.buffer, self.camera.sensors.items[sensor].extent);

        // copy our stuff
        self.encoder.barrier(&[_]Encoder.ImageBarrier {
            Encoder.ImageBarrier {
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_storage_write_bit = true, .shader_storage_read_bit = true },
                .dst_stage_mask = .{ .copy_bit = true },
                .dst_access_mask = .{ .transfer_read_bit = true },
                .image = self.camera.sensors.items[sensor].image.handle,
            }
        }, &.{});

        // copy rendered image to host-visible staging buffer
        self.encoder.copyImageToBuffer(self.camera.sensors.items[sensor].image.handle, self.camera.sensors.items[sensor].extent, self.output_buffers.items[sensor].handle);

        self.encoder.submitAndIdleUntilDone(&self.vc) catch return false;
        self.encoder.begin() catch return false;

        self.camera.sensors.items[sensor].sample_count += 1;
        self.frame_index += 1;

        return true;
    }

    pub export fn HdMoonshineRebuildPipeline(self: *HdMoonshine) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const old_pipeline = self.pipeline.recreate(&self.vc, pipeline_settings) catch return false;
        self.vc.device.destroyPipeline(old_pipeline, null);
        return true;
    }

    pub export fn HdMoonshineCreateMesh(self: *HdMoonshine, positions: [*]const F32x3, maybe_normals: ?[*]const F32x3, maybe_texcoords: ?[*]const F32x2, attribute_count: usize) MeshManager.Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const upload = self.encoder.uploadAllocator();

        const positions_staging = upload.alloc(F32x3, attribute_count) catch @panic("internal error"); // TODO: error recovery
        @memcpy(positions_staging, positions[0..attribute_count]);

        const normals_slice = if (maybe_normals) |normals| blk: {
            const staging = upload.alloc(F32x3, attribute_count) catch @panic("internal error"); // TODO: error recovery
            @memcpy(staging, normals[0..attribute_count]);
            break :blk self.encoder.upload_allocator.getBufferSlice(staging);
        } else null;

        const texcoords_slice = if (maybe_texcoords) |texcoords| blk: {
            const staging = upload.alloc(F32x2, attribute_count) catch @panic("internal error"); // TODO: error recovery
            @memcpy(staging, texcoords[0..attribute_count]);
            break :blk self.encoder.upload_allocator.getBufferSlice(staging);
        } else null;

        return self.world.meshes.upload(&self.vc, self.allocator.allocator(), &self.encoder, .{
            .name = "hydra",
            .positions = self.encoder.upload_allocator.getBufferSlice(positions_staging),
            .normals = normals_slice,
            .texcoords = texcoords_slice,
            .indices = null,
        }) catch @panic("internal error"); // TODO: error recovery
    }

    pub export fn HdMoonshineCreateTexture(self: *HdMoonshine, data: [*]u8, extent: vk.Extent2D, format: TextureFormat, name: [*:0]const u8) TextureManager.Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const typed_data = data[0..extent.width * extent.height * format.pixelSizeInBytes()];
        const staging = self.encoder.uploadAllocator().alignedAlloc(u8, .fromByteUnits(16), typed_data.len) catch @panic("internal error"); // TODO: error recovery
        @memcpy(staging, data);
        return self.world.materials.textures.upload(&self.vc, self.allocator.allocator(), &self.encoder, self.encoder.upload_allocator.getBufferSlice(staging).asBytes(), extent, format.toVk(), std.mem.span(name)) catch @panic("internal error"); // TODO: error recovery
    }

    pub export fn HdMoonshineCreateMaterial(self: *HdMoonshine, material: Material) MaterialManager.Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.world.materials.upload(&self.vc, self.allocator.allocator(), &self.encoder, .{
            .name = "hydra",
            .normal = material.normal,
            .emissive = material.emissive,
            .bsdf = .{ .standard_pbr = .{
                .color = material.color,
                .metalness = material.metalness,
                .roughness = material.roughness,
                .ior = .{ .a = material.ior, .b = 0 },
            } },
        }) catch @panic("internal error"); // TODO: error recovery
    }

    fn updateMaterialField(self: *HdMoonshine, material: MaterialManager.Handle, comptime field: []const u8, value: anytype) void {
        const offset = @sizeOf(MaterialManager.Material.Device) * material + @offsetOf(MaterialManager.Material.Device, field);
        self.encoder.buffer.updateBuffer(self.world.materials.materials.handle, offset, @sizeOf(@TypeOf(value)), &value);
        self.materials_dirty = true;
    }

    fn updateStandardPbrField(self: *HdMoonshine, material: MaterialManager.Handle, comptime field: []const u8, value: anytype) void {
        const offset = @sizeOf(MaterialManager.StandardPBR) * material + @offsetOf(MaterialManager.StandardPBR, field);
        self.encoder.buffer.updateBuffer(self.world.materials.variant_buffers.standard_pbr.buffer.handle, offset, @sizeOf(@TypeOf(value)), &value);
        self.materials_dirty = true;
    }

    pub export fn HdMoonshineSetMaterialNormal(self: *HdMoonshine, material: MaterialManager.Handle, image: TextureManager.Handle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.updateMaterialField(material, "normal", image);
    }

    pub export fn HdMoonshineSetMaterialEmissive(self: *HdMoonshine, material: MaterialManager.Handle, image: TextureManager.Handle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.updateMaterialField(material, "emissive", image);
    }

    pub export fn HdMoonshineSetMaterialColor(self: *HdMoonshine, material: MaterialManager.Handle, image: TextureManager.Handle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.updateStandardPbrField(material, "color", image);
    }

    pub export fn HdMoonshineSetMaterialMetalness(self: *HdMoonshine, material: MaterialManager.Handle, image: TextureManager.Handle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.updateStandardPbrField(material, "metalness", image);
    }

    pub export fn HdMoonshineSetMaterialRoughness(self: *HdMoonshine, material: MaterialManager.Handle, image: TextureManager.Handle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.updateStandardPbrField(material, "roughness", image);
    }

    pub export fn HdMoonshineSetMaterialIOR(self: *HdMoonshine, material: MaterialManager.Handle, ior: f32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.updateStandardPbrField(material, "ior", MaterialManager.CauchyIOR { .a = ior, .b = 0 });
    }

    pub export fn HdMoonshineCreateInstance(self: *HdMoonshine, transform: Mat4x3, mesh: MeshManager.Handle, material: MaterialManager.Handle, visible: bool) Accel.Handle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const geometries = [_]ModelManager.Geometry.Parameters {
            .{ .mesh = mesh, .material = material },
        };
        const model = self.world.models.upload(&self.vc, self.allocator.allocator(), &self.encoder, self.world.meshes, self.world.materials, &geometries) catch @panic("internal error"); // TODO: error recovery

        const handle = self.world.accel.uploadInstance(&self.vc, &self.encoder, self.world.models, .{
            .transform = transform,
            .visible = visible,
            .model = model,
        }) catch @panic("internal error"); // TODO: error recovery

        std.debug.assert(model == handle);

        self.instances_dirty = true;
        return handle;
    }

    pub export fn HdMoonshineDestroyInstance(self: *HdMoonshine, handle: Accel.Handle) void {
        // sike, just hide it. TODO: proper destruction
        HdMoonshineSetInstance(self, handle, Mat4.identity.truncateRow(), false);
    }

    pub export fn HdMoonshineSetInstance(self: *HdMoonshine, handle: Accel.Handle, transform: Mat4x3, visible: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.world.accel.recordSetInstance(&self.vc, &self.encoder, self.world.models, handle, .{
            .transform = transform,
            .visible = visible,
            .model = @intCast(handle),
        });
        self.instances_dirty = true;
    }

    pub export fn HdMoonshineCreateSensor(self: *HdMoonshine, extent: vk.Extent2D) Camera.SensorHandle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.output_buffers.append(self.allocator.allocator(), core.mem.DownloadBuffer([4]f32).create(&self.vc, extent.width * extent.height, "output") catch @panic("internal error")) catch @panic("internal error");
        return self.camera.appendSensor(&self.vc, self.allocator.allocator(), extent, engine.color.Chromaticities.bt709) catch @panic("internal error"); // TODO: error recovery
    }

    pub export fn HdMoonshineGetSensorData(self: *const HdMoonshine, sensor: Camera.SensorHandle) [*][4]f32 {
        return self.output_buffers.items[sensor].hostSlice().ptr;
    }

    pub export fn HdMoonshineClearSensor(self: *HdMoonshine, sensor: Camera.SensorHandle) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.camera.sensors.items[sensor].clear();
    }

    pub export fn HdMoonshineGetSensorSampleCount(self: *const HdMoonshine, sensor: Camera.SensorHandle) u32 {
        return self.camera.sensors.items[sensor].sample_count;
    }

    pub export fn HdMoonshineCreateCamera(self: *HdMoonshine, thin_lens: Camera.ThinLens, transform: Mat4x3, name: [*:0]const u8) Camera.CameraHandle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.camera.appendCamera(self.allocator.allocator(), Camera.Camera {
            .transform = transform,
            .model = .thin_lens,
            .thin_lens = thin_lens,
        }, self.allocator.allocator().dupeZ(u8, std.mem.span(name)) catch @panic("internal error")) catch @panic("internal error"); // TODO: error recovery
    }

    pub export fn HdMoonshineSetCamera(self: *HdMoonshine, handle: Camera.CameraHandle, thin_lens: Camera.ThinLens, transform: Mat4x3) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.camera.cameras.items[handle][1] = Camera.Camera {
            .transform = transform,
            .model = .thin_lens,
            .thin_lens = thin_lens,
        };
    }

    pub export fn HdMoonshineSetEnvMap(self: *HdMoonshine, data: [*]const u8, extent: vk.Extent2D, format: TextureFormat, transform: Mat3) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const typed_data = data[0..extent.width * extent.height * format.pixelSizeInBytes()];
        const staging = self.encoder.uploadAllocator().alignedAlloc(u8, .fromByteUnits(16), typed_data.len) catch @panic("internal error"); // TODO: error recovery
        @memcpy(staging, typed_data);

        self.encoder.attachResource(self.background.backgrounds.pop().?.image) catch @panic("internal error"); // TODO: error recovery
        self.current_background = self.background.addBackground(&self.vc, self.allocator.allocator(), &self.encoder, self.encoder.upload_allocator.getBufferSlice(staging).asBytes(), extent, format.toVk(), transform, "dome") catch @panic("internal error"); // TODO: error recovery
    }

    pub export fn HdMoonshineDestroy(self: *HdMoonshine) void {
        self.encoder.submitAndIdleUntilDone(&self.vc) catch {};

        for (self.output_buffers.items) |output_buffer| {
            output_buffer.destroy(&self.vc);
        }
        self.output_buffers.deinit(self.allocator.allocator());
        self.pipeline.destroy(&self.vc);
        self.world.destroy(&self.vc, self.allocator.allocator());
        self.background.destroy(&self.vc, self.allocator.allocator());
        self.camera.destroy(&self.vc, self.allocator.allocator());
        self.encoder.destroy(&self.vc);
        self.vc.destroy(self.allocator.allocator());
        self.io_threaded.deinit();
        var alloc = self.allocator;
        alloc.allocator().destroy(self);
        _ = alloc.deinit();
    }
};

