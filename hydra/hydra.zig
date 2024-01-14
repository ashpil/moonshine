const std = @import("std");
const vk = @import("vulkan");

const engine = @import("engine");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Commands = core.Commands;
const VkAllocator = core.Allocator;
const ImageManager = core.ImageManager;

const hrtsystem = engine.hrtsystem;
const World = hrtsystem.World;
const Camera = hrtsystem.Camera;
const Background = hrtsystem.BackgroundManager;
const MeshManager = hrtsystem.MeshManager;
const MaterialManager = hrtsystem.MaterialManager;
const Accel = hrtsystem.Accel;
const Pipeline = hrtsystem.pipeline.StandardPipeline;

const vector = engine.vector;
const F32x2 = vector.Vec2(f32);
const F32x3 = vector.Vec3(f32);
const U32x3 = vector.Vec3(u32);
const Mat3x4 = vector.Mat3x4(f32);

pub const vulkan_context_device_functions = hrtsystem.required_device_functions;

const Allocator = std.heap.GeneralPurposeAllocator(.{});

comptime {
    _ = HdMoonshine;
}

pub const HdMoonshine = struct {
    allocator: Allocator,
    vk_allocator: VkAllocator,
    vc: VulkanContext,
    commands: Commands,

    world: World,
    camera: Camera,
    background: Background,

    pipeline: Pipeline,

    output_buffer: VkAllocator.HostBuffer([4]f32),

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

        // TODO: use actually passed camera
        self.camera = Camera.create(&self.vc, &self.vk_allocator, self.allocator.allocator(), vk.Extent2D { .width = 601, .height = 495}, Camera.CreateInfo {
            .origin = F32x3.new(-5, 0, 0),
            .forward = F32x3.new(1, 0, 0),
            .up = F32x3.new(0, 0, 1),
            .vfov = std.math.pi / 3.0,
            .aspect = 601.0 / 495.0,
            .aperture = 0,
            .focus_distance = 1,
        }) catch return null;
        errdefer self.camera.destroy(&self.vc, self.allocator.allocator());

        self.background = Background.create(&self.vc) catch return null;
        errdefer self.background.destroy(&self.vc, self.allocator.allocator());
        self.background.addDefaultBackground(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands) catch return null;

        self.pipeline = Pipeline.create(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, .{ self.world.descriptor_layout, self.background.descriptor_layout, self.camera.descriptor_layout }, .{
            .@"0" = .{
                .samples_per_run = 1,
                .max_bounces = 1024,
                .env_samples_per_bounce = 1,
                .mesh_samples_per_bounce = 1,
            }
        }) catch return null;
        errdefer self.pipeline.destroy(&self.vc);

        self.output_buffer = self.vk_allocator.createHostBuffer(&self.vc, [4]f32, self.camera.sensor.extent.width * self.camera.sensor.extent.height, .{ .transfer_dst_bit = true }) catch return null;
        errdefer self.output_buffer.destroy(&self.vc);

        return self;
    }

    pub export fn HdMoonshineRender(self: *HdMoonshine, out: [*]f32) bool {
        self.commands.startRecording(&self.vc) catch return false;

        // prepare our stuff
        self.camera.sensor.recordPrepareForCapture(&self.vc, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true });

        // bind our stuff
        self.pipeline.recordBindPipeline(&self.vc, self.commands.buffer);
        self.pipeline.recordBindDescriptorSets(&self.vc, self.commands.buffer, [_]vk.DescriptorSet { self.world.descriptor_set, self.background.data.items[0].descriptor_set, self.camera.sensor.descriptor_set });

        // push our stuff
        const bytes = std.mem.asBytes(&.{ self.camera.properties, @as(u32, 0) });
        self.vc.device.cmdPushConstants(self.commands.buffer, self.pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

        // trace our stuff
        self.pipeline.recordTraceRays(&self.vc, self.commands.buffer, self.camera.sensor.extent);

        // copy our stuff
        self.camera.sensor.recordPrepareForCopy(&self.vc, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true }, .{ .copy_bit = true });

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
                .width = self.camera.sensor.extent.width,
                .height = self.camera.sensor.extent.height,
                .depth = 1,
            },
        };
        self.vc.device.cmdCopyImageToBuffer(self.commands.buffer, self.camera.sensor.images.data.items(.handle)[0], .transfer_src_optimal, self.output_buffer.handle, 1, @ptrCast(&copy));

        self.commands.submitAndIdleUntilDone(&self.vc) catch return false;

        @memcpy(@as([*][4]f32, @ptrCast(out)), self.output_buffer.data);

        return true;
    }

    pub export fn HdMoonshineCreateMesh(self: *HdMoonshine, positions: [*]const F32x3, maybe_normals: ?[*]const F32x3, maybe_texcoords: ?[*]const F32x2, vertex_count: usize, indices: [*]const U32x3, index_count: usize) MeshManager.Handle {
        const mesh = MeshManager.Mesh {
            .positions = positions[0..vertex_count],
            .normals = if (maybe_normals) |normals| normals[0..vertex_count] else null,
            .texcoords = if (maybe_texcoords) |texcoords| texcoords[0..vertex_count] else null,
            .indices = indices[0..index_count],
        };
        return self.world.mesh_manager.uploadMesh(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, mesh) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineCreateSolidTexture1(self: *HdMoonshine, source: f32, name: [*:0]const u8) ImageManager.Handle {
        return self.world.material_manager.textures.uploadTexture(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, ImageManager.TextureSource {
            .f32x1 = source,
        }, std.mem.span(name)) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineCreateSolidTexture2(self: *HdMoonshine, source: F32x2, name: [*:0]const u8) ImageManager.Handle {
        return self.world.material_manager.textures.uploadTexture(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, ImageManager.TextureSource {
            .f32x2 = source,
        }, std.mem.span(name)) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineCreateSolidTexture3(self: *HdMoonshine, source: F32x3, name: [*:0]const u8) ImageManager.Handle {
        return self.world.material_manager.textures.uploadTexture(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, ImageManager.TextureSource {
            .f32x3 = source,
        }, std.mem.span(name)) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineCreateMaterialLambert(self: *HdMoonshine, normal: ImageManager.Handle, emissive: ImageManager.Handle, color: ImageManager.Handle) MaterialManager.Handle {
        return self.world.material_manager.uploadMaterial(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, MaterialManager.MaterialInfo {
            .normal = normal,
            .emissive = emissive,
            .variant = MaterialManager.MaterialVariant {
                .lambert = MaterialManager.Lambert {
                    .color = color,
                },
            },
        }) catch unreachable; // TODO: error handling
    }

    pub export fn HdMoonshineCreateInstance(self: *HdMoonshine, transform: Mat3x4, geometries: [*]const Accel.Geometry, geometry_count: usize) bool {
        const instance = Accel.Instance {
            .transform = transform,
            .visible = true,
            .geometries = geometries[0..geometry_count],
        };
        self.world.accel.uploadInstance(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, self.world.mesh_manager, instance) catch return false;
        self.world.createDescriptorSet(&self.vc, self.allocator.allocator()) catch return false;
        return true;
    }

    pub export fn HdMoonshineDestroy(self: *HdMoonshine) void {
        self.output_buffer.destroy(&self.vc);
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

