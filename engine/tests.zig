const std = @import("std");
const vk = @import("vulkan");

const engine = @import("engine");

const VulkanContext = engine.core.VulkanContext;
const Commands = engine.core.Commands;
const VkAllocator = engine.core.Allocator;
const StorageImageManager = engine.core.Images.StorageImageManager;
const TextureManager = engine.core.Images.TextureManager;
const Pipeline = engine.hrtsystem.pipeline.StandardPipeline;
const Scene = engine.hrtsystem.Scene;
const World = engine.hrtsystem.World;
const MeshManager = engine.hrtsystem.MeshManager;
const MaterialManager = engine.hrtsystem.MaterialManager;
const Accel = engine.hrtsystem.Accel;
const Camera = engine.hrtsystem.Camera;
const Background = engine.hrtsystem.BackgroundManager;

const exr = engine.fileformats.exr;
const Rgba2D = exr.helpers.Rgba2D;

const vector = engine.vector;
const F32x3 = vector.Vec3(f32);
const U32x3 = vector.Vec3(u32);
const Mat3x4 = vector.Mat3x4(f32);

const utils = engine.core.vk_helpers;

const TestingContext = struct {
    vc: VulkanContext,
    vk_allocator: VkAllocator,
    commands: Commands,
    textures: TextureManager,
    images: StorageImageManager,
    output_buffer: VkAllocator.HostBuffer([4]f32),

    fn create(allocator: std.mem.Allocator, extent: vk.Extent2D) !TestingContext {
        const vc = try VulkanContext.create(allocator, "engine-tests", &.{}, &engine.hrtsystem.required_device_extensions, &engine.hrtsystem.required_device_features, null);
        errdefer vc.destroy();

        var vk_allocator = try VkAllocator.create(&vc, allocator);
        errdefer vk_allocator.destroy(&vc, allocator);

        var commands = try Commands.create(&vc);
        errdefer commands.destroy(&vc);

        const output_buffer = try vk_allocator.createHostBuffer(&vc, [4]f32, extent.width * extent.height, .{ .transfer_dst_bit = true });
        errdefer output_buffer.destroy(&vc);

        var textures = try TextureManager.create(&vc);
        errdefer textures.destroy(&vc, allocator);

        return TestingContext {
            .vc = vc,
            .vk_allocator = vk_allocator,
            .commands = commands,
            .images = StorageImageManager {},
            .textures = textures,
            .output_buffer = output_buffer,
        };
    }

    fn renderToOutput(self: *TestingContext, pipeline: *const Pipeline, scene: *const Scene) !void {
        try self.commands.startRecording(&self.vc);

        // prepare our stuff
        scene.camera.sensors.items[0].recordPrepareForCapture(&self.vc, &self.images, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true });

        // bind our stuff
        pipeline.recordBindPipeline(&self.vc, self.commands.buffer);
        pipeline.recordBindDescriptorSets(&self.vc, self.commands.buffer, [_]vk.DescriptorSet { self.textures.descriptor_set, scene.world.descriptor_set, scene.background.data.items[0].descriptor_set, scene.camera.sensors.items[0].descriptor_set });

        // push our stuff
        const bytes = std.mem.asBytes(&.{ scene.camera.lenses.items[0], scene.camera.sensors.items[0].sample_count, scene.background.data.items[0].texture });
        self.vc.device.cmdPushConstants(self.commands.buffer, pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

        // trace our stuff
        pipeline.recordTraceRays(&self.vc, self.commands.buffer, scene.camera.sensors.items[0].extent);

        // copy our stuff
        scene.camera.sensors.items[0].recordPrepareForCopy(&self.vc, &self.images, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true }, .{ .copy_bit = true });

        // copy output image to host-visible staging buffer
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
                .width = scene.camera.sensors.items[0].extent.width,
                .height = scene.camera.sensors.items[0].extent.height,
                .depth = 1,
            },
        };
        self.vc.device.cmdCopyImageToBuffer(self.commands.buffer, self.images.data.get(scene.camera.sensors.items[0].image).handle, .transfer_src_optimal, self.output_buffer.handle, 1, @ptrCast(&copy));

        try self.commands.submitAndIdleUntilDone(&self.vc);
    }

    fn destroy(self: *TestingContext, allocator: std.mem.Allocator) void {
        self.output_buffer.destroy(&self.vc);
        self.commands.destroy(&self.vc);
        self.images.destroy(&self.vc, allocator);
        self.vk_allocator.destroy(&self.vc, allocator);
        self.vc.destroy();
    }
};

// creates a unit icosphere placed at the origin with the specified subdivision level
//
// http://blog.andreaskahler.com/2009/06/creating-icosphere-mesh-in-code.html
// https://observablehq.com/@mourner/fast-icosphere-mesh
fn icosphere(order: usize, allocator: std.mem.Allocator, reverse_winding_order: bool) !MeshManager.Mesh {
    const Subdivider = struct {
        const MidpointCache = std.AutoArrayHashMapUnmanaged(u64, u32);

        const Self = @This();

        cache: MidpointCache,
        positions: std.ArrayListUnmanaged(F32x3),
        triangles: std.ArrayListUnmanaged(U32x3),

        allocator: std.mem.Allocator,

        fn init(gpa: std.mem.Allocator, initial_positions: []const F32x3, initial_triangles: []const U32x3) std.mem.Allocator.Error!Self {
            return Self {
              .cache = MidpointCache {},
              .positions = std.ArrayListUnmanaged(F32x3).fromOwnedSlice(try gpa.dupe(F32x3, initial_positions)),
              .triangles = std.ArrayListUnmanaged(U32x3).fromOwnedSlice(try gpa.dupe(U32x3, initial_triangles)),
              .allocator = gpa,
            };
        }

        fn deinit(self: *Self) void {
            self.cache.deinit(self.allocator);
            self.positions.deinit(self.allocator);
            self.triangles.deinit(self.allocator);
        }

        fn subdivide(self: *Self) std.mem.Allocator.Error!void {
            var next_triangles = std.ArrayListUnmanaged(U32x3) {};
            for (self.triangles.items) |triangle| {
                const a = try self.get_midpoint(triangle.x, triangle.y);
                const b = try self.get_midpoint(triangle.y, triangle.z);
                const c = try self.get_midpoint(triangle.z, triangle.x);

                try next_triangles.append(self.allocator, U32x3.new(triangle.x, a, c));
                try next_triangles.append(self.allocator, U32x3.new(triangle.y, b, a));
                try next_triangles.append(self.allocator, U32x3.new(triangle.z, c, b));
                try next_triangles.append(self.allocator, U32x3.new(a, b, c));
            }
            self.triangles.deinit(self.allocator);
            self.triangles = next_triangles;
        }

        fn get_midpoint(self: *Self, index1: u32, index2: u32) std.mem.Allocator.Error!u32 {
            const smaller = if (index1 < index2) index1 else index2;
            const greater = if (index1 < index2) index2 else index1;
            const key = (@as(u64, @intCast(smaller)) << 32) + greater;

            if (self.cache.get(key)) |x| {
                return x;
            }  else {
                const point1 = self.positions.items[index1];
                const point2 = self.positions.items[index2];
                const midpoint = point1.add(point2).div_scalar(2.0);
                try self.positions.append(self.allocator, midpoint);

                const new_index: u32 = @intCast(self.positions.items.len - 1);
                try self.cache.put(self.allocator, key, new_index);

                return new_index;
            }
        }
    };

    // create icosahedron
    const t = (1.0 + std.math.sqrt(5.0)) / 2.0;

    const initial_positions = [12]F32x3 {
        F32x3.new(-1,  t,  0),
        F32x3.new( 1,  t,  0),
        F32x3.new(-1, -t,  0),
        F32x3.new( 1, -t,  0),
        F32x3.new( 0, -1,  t),
        F32x3.new( 0,  1,  t),
        F32x3.new( 0, -1, -t),
        F32x3.new( 0,  1, -t),
        F32x3.new( t,  0, -1),
        F32x3.new( t,  0,  1),
        F32x3.new(-t,  0, -1),
        F32x3.new(-t,  0,  1),
    };

    const initial_triangles = [20]U32x3 {
        U32x3.new(0, 11, 5),
        U32x3.new(0, 5, 1),
        U32x3.new(0, 1, 7),
        U32x3.new(0, 7, 10),
        U32x3.new(0, 10, 11),
        U32x3.new(1, 5, 9),
        U32x3.new(5, 11, 4),
        U32x3.new(11, 10, 2),
        U32x3.new(10, 7, 6),
        U32x3.new(7, 1, 8),
        U32x3.new(3, 9, 4),
        U32x3.new(3, 4, 2),
        U32x3.new(3, 2, 6),
        U32x3.new(3, 6, 8),
        U32x3.new(3, 8, 9),
        U32x3.new(4, 9, 5),
        U32x3.new(2, 4, 11),
        U32x3.new(6, 2, 10),
        U32x3.new(8, 6, 7),
        U32x3.new(9, 8, 1),
    };

    var subdivider = try Subdivider.init(allocator, &initial_positions, &initial_triangles);
    defer subdivider.deinit();

    for (0..order) |_| {
        try subdivider.subdivide();
    }

    const positions = try allocator.dupe(F32x3, subdivider.positions.items);

    for (positions) |*position| {
        position.* = position.unit();
    }

    const indices = try allocator.dupe(U32x3, subdivider.triangles.items);
    if (reverse_winding_order) {
        for (indices) |*index| {
            index.* = U32x3.new(index.z, index.y, index.x);
        }
    }

    const mesh = MeshManager.Mesh {
        .positions = positions,
        .normals = null, // TODO: add normals here when normals are robust enough
        .texcoords = null,
        .indices = indices,
    };
    return mesh;
}

// TODO: use actual statistical tests

// theoretically any convex shape works for the furnace test
// the reason to use a sphere (rather than e.g., a box or pyramid with less geometric complexity)
// is that a sphere will test the BRDF with all incoming directions
// this is technically an argument for supporting primitives other than triangles,
// if the goal is just to test the BRDF in the most comprehensive way

test "white sphere on white background is white" {
    const allocator = std.testing.allocator;
    const extent = vk.Extent2D { .width = 32, .height = 32 };
    var tc = try TestingContext.create(allocator, extent);
    defer tc.destroy(allocator);

    var world = try World.createEmpty(&tc.vc);
    defer world.destroy(&tc.vc, allocator);

    // add sphere to world
    {
        const mesh_handle = try world.mesh_manager.uploadMesh(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, try icosphere(5, allocator, false));

        const normal_texture = try tc.textures.uploadTexture(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, TextureManager.Source {
            .f32x2 = MaterialManager.MaterialInfo.default_normal,
        }, "");
        const albedo_texture = try tc.textures.uploadTexture(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, TextureManager.Source {
            .f32x3 = F32x3.new(1, 1, 1),
        }, "");
        const emissive_texture = try tc.textures.uploadTexture(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, TextureManager.Source {
            .f32x3 = F32x3.new(0, 0, 0),
        }, "");
        const material_handle = try world.material_manager.uploadMaterial(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, MaterialManager.MaterialInfo {
            .normal = normal_texture,
            .emissive = emissive_texture,
            .variant = MaterialManager.MaterialVariant {
                .lambert = MaterialManager.Lambert {
                    .color = albedo_texture,
                }
            }
        });

        try world.accel.uploadInstance(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, world.mesh_manager, Accel.Instance {
            .visible = true,
            .transform = Mat3x4.identity,
            .geometries = &[1]Accel.Geometry {
                .{
                    .material = material_handle,
                    .mesh = mesh_handle,
                    .sampled = false,
                }
            },
        });

        try world.createDescriptorSet(&tc.vc);
    }

    var camera = try Camera.create(&tc.vc);
    _ = try camera.appendLens(allocator, Camera.Lens {
        .origin = F32x3.new(-3, 0, 0),
        .forward = F32x3.new(1, 0, 0),
        .up = F32x3.new(0, 0, 1),
        .vfov = std.math.pi / 4.0,
        .aperture = 0,
        .focus_distance = 1,
    });
    _ = try camera.appendSensor(&tc.vc, &tc.vk_allocator, allocator, &tc.images, extent);
    defer camera.destroy(&tc.vc, allocator);

    var background = try Background.create(&tc.vc);
    defer background.destroy(&tc.vc, allocator);
    var white = [4]f32 {1, 1, 1, 1};
    const image = Rgba2D {
        .ptr = @ptrCast(&white),
        .extent = .{
            .width = 1,
            .height = 1,
        }
    };
    try background.addBackground(&tc.vc, &tc.vk_allocator, allocator, &tc.textures, &tc.commands, image, "white");

    var scene = Scene {
        .world = world,
        .camera = camera,
        .background = background,
    };

    var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ tc.textures.descriptor_layout, scene.world.descriptor_layout, scene.background.descriptor_layout, scene.camera.descriptor_layout }, .{
        .@"0" = .{
            .samples_per_run = 512,
            .max_bounces = 1024,
            .env_samples_per_bounce = 0, // TODO: test with env sampling once that works well with small env maps
            .mesh_samples_per_bounce = 0,
        }
    });
    defer pipeline.destroy(&tc.vc);

    try tc.renderToOutput(&pipeline, &scene);

    for (tc.output_buffer.data) |pixel| {
        for (pixel[0..3]) |component| {
            if (!std.math.approxEqAbs(f32, component, 1.0, 0.00001)) return error.NonWhitePixel;
        }
    }
}

test "inside illuminating sphere is white" {
    const allocator = std.testing.allocator;

    const extent = vk.Extent2D { .width = 32, .height = 32 };
    var tc = try TestingContext.create(allocator, extent);
    defer tc.destroy(allocator);

    var world = try World.createEmpty(&tc.vc);
    defer world.destroy(&tc.vc, allocator);

    // add sphere to world
    {
        const mesh_handle = try world.mesh_manager.uploadMesh(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, try icosphere(5, allocator, true));

        const normal_texture = try tc.textures.uploadTexture(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, TextureManager.Source {
            .f32x2 = MaterialManager.MaterialInfo.default_normal,
        }, "");
        const albedo_texture = try tc.textures.uploadTexture(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, TextureManager.Source {
            .f32x3 = F32x3.new(0.5, 0.5, 0.5),
        }, "");
        const emissive_texture = try tc.textures.uploadTexture(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, TextureManager.Source {
            .f32x3 = F32x3.new(0.5, 0.5, 0.5),
        }, "");
        const material_handle = try world.material_manager.uploadMaterial(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, MaterialManager.MaterialInfo {
            .normal = normal_texture,
            .emissive = emissive_texture,
            .variant = MaterialManager.MaterialVariant {
                .lambert = MaterialManager.Lambert {
                    .color = albedo_texture,
                }
            }
        });

        try world.accel.uploadInstance(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, world.mesh_manager, Accel.Instance {
            .visible = true,
            .transform = Mat3x4.identity,
            .geometries = &[1]Accel.Geometry {
                .{
                    .material = material_handle,
                    .mesh = mesh_handle,
                    .sampled = false,
                }
            },
        });

        try world.createDescriptorSet(&tc.vc);
    }

    var camera = try Camera.create(&tc.vc);
    _ = try camera.appendLens(allocator, Camera.Lens {
        .origin = F32x3.new(0, 0, 0),
        .forward = F32x3.new(1, 0, 0),
        .up = F32x3.new(0, 0, 1),
        .vfov = std.math.pi / 3.0,
        .aperture = 0,
        .focus_distance = 1,
    });
    _ = try camera.appendSensor(&tc.vc, &tc.vk_allocator, allocator, &tc.images, extent);
    defer camera.destroy(&tc.vc, allocator);

    var background = try Background.create(&tc.vc);
    defer background.destroy(&tc.vc, allocator);
    var black = [4]f32 {0, 0, 0, 1};
    const image = Rgba2D {
        .ptr = @ptrCast(&black),
        .extent = .{
            .width = 1,
            .height = 1,
        }
    };
    try background.addBackground(&tc.vc, &tc.vk_allocator, allocator, &tc.textures, &tc.commands, image, "black");

    var scene = Scene {
        .world = world,
        .camera = camera,
        .background = background,
    };

    var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ tc.textures.descriptor_layout, scene.world.descriptor_layout, scene.background.descriptor_layout, scene.camera.descriptor_layout }, .{
        .@"0" = .{
            .samples_per_run = 1024,
            .max_bounces = 1024,
            .env_samples_per_bounce = 0,
            .mesh_samples_per_bounce = 0,
        }
    });
    defer pipeline.destroy(&tc.vc);

    try tc.renderToOutput(&pipeline, &scene);

    for (tc.output_buffer.data) |pixel| {
        for (pixel[0..3]) |component| {
            if (!std.math.approxEqAbs(f32, component, 1.0, 0.02)) return error.NonWhitePixel;
        }
    }
}

// TODO: revive this once mesh sampling works with instance upload API
// test "inside illuminating sphere is white with mesh sampling" {
//     const allocator = std.testing.allocator;

//     const extent = vk.Extent2D { .width = 32, .height = 32 };
//     var tc = try TestingContext.create(allocator, extent);
//     defer tc.destroy(allocator);

//     var scene = try Scene.fromGlbExr(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, "assets/sphere_internal.glb", "assets/white.exr", extent, false);
//     defer scene.destroy(&tc.vc, allocator);

//     var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ scene.world.descriptor_layout, scene.background.descriptor_layout, scene.camera.descriptor_layout }, .{
//         .@"0" = .{
//             .samples_per_run = 512,
//             .max_bounces = 1024,
//             .env_samples_per_bounce = 0,
//             .mesh_samples_per_bounce = 1,
//         }
//     });
//     defer pipeline.destroy(&tc.vc);

//     try tc.renderToOutput(&pipeline, &scene);

//     for (tc.output_buffer.data) |pixel| {
//         for (pixel[0..3]) |component| {
//             // TODO: this should be able to have tighter error bounds but is weird on my GPU for some reason
//             // first upgrade GPU then determine if bug actually exists
//             if (!std.math.approxEqAbs(f32, component, 1.0, 0.1)) return error.NonWhitePixel;
//         }
//     }
// }
