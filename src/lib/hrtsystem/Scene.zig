const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");

const engine = @import("../engine.zig");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;

const Background = @import("./BackgroundManager.zig");
const World = @import("./World.zig");
const Camera = @import("./CameraManager.zig");
const Material = @import("./MaterialManager.zig");

const exr = engine.fileformats.exr;

const vector = @import("../vector.zig");
const F32x3 = vector.Vec3(f32);
const F32x4 = vector.Vec4(f32);
const Mat3 = vector.Mat3(f32);
const Mat4 = vector.Mat4(f32);
const Mat4x3 = vector.Mat4x3(f32);

const Self = @This();

world: World,
background: Background,
camera: Camera,
global_volume: Material.Volume = .{},

// glTF doesn't correspond very well to the internal data structures here so this is very inefficient
// also very inefficient because it's written very inefficiently, can remove a lot of copying, but that's a problem for another time
// inspection bool specifies whether some buffers should be created with the `transfer_src_flag` for inspection
pub fn fromGltfExr(vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, gltf_filepath: []const u8, skybox_filepath: []const u8, extent: vk.Extent2D) !Self {
    var gltf = Gltf.init(allocator);
    defer gltf.deinit();

    const buffer = try std.fs.cwd().readFileAllocOptions(
        allocator,
        gltf_filepath,
        std.math.maxInt(usize),
        null,
        4,
        null
    );
    defer allocator.free(buffer);
    try gltf.parse(buffer);

    var camera = Camera {};
    errdefer camera.destroy(vc, allocator);
    _ = try camera.appendSensor(vc, allocator, extent);

    {
        // gltf spec:
        // > The camera is defined such that the local +X axis is to the right,
        // > the “lens” looks towards the local -Z axis,
        // > and the top of the camera is aligned with the local +Y axis.
        const msne_camera_to_gltf_camera = Mat4.fromRows(.{
            .new(.{ 0, 1, 0, 0}),
            .new(.{ 0, 0,-1, 0}),
            .new(.{-1, 0, 0, 0}),
            .new(.{ 0, 0, 0, 1}),
        });

        for (gltf.data.nodes.items) |node| {
            if (node.camera) |camera_idx| {
                const gltf_camera = gltf.data.cameras.items[camera_idx];
                const mat_array = Gltf.getGlobalTransform(&gltf.data, node);
                const transform = Mat4.fromCols(.{ .new(mat_array[0]), .new(mat_array[1]), .new(mat_array[2]), .new(mat_array[3]) });
                _ = try camera.appendCamera(allocator, Camera.Camera {
                    .transform = World.gltf_to_msne.mul(transform).mul(msne_camera_to_gltf_camera).truncateRow(),
                    .model = switch (gltf_camera.type) {
                        .perspective => .thin_lens,
                        .orthographic => .orthographic,
                    },
                    .thin_lens = Camera.ThinLens {
                        .vfov = if (gltf_camera.type == .perspective) gltf_camera.type.perspective.yfov else std.math.pi / 4.0,
                    },
                    .orthographic = Camera.Orthographic {
                        .vscale = if (gltf_camera.type == .orthographic) gltf_camera.type.orthographic.ymag else 1,
                    },
                }, try allocator.dupeZ(u8, gltf_camera.name));
            }
        }

        // add default camera if none loaded
        if (camera.cameras.items.len == 0) {
            const transform = Mat4.fromRows(.{
                .new(.{1, 0, 0, 0}),
                .new(.{0, 1, 0, 0}),
                .new(.{0, 0, 1, 5}), // looking at origin
                .new(.{0, 0, 0, 1}),
            });
            _ = try camera.appendCamera(allocator, Camera.Camera {
                .transform = World.gltf_to_msne.mul(transform).mul(msne_camera_to_gltf_camera).truncateRow(),
            }, try allocator.dupeZ(u8, "default"));
        }
    }

    var world = try World.fromGltf(vc, allocator, encoder, gltf, std.fs.path.dirname(gltf_filepath));
    errdefer world.destroy(vc, allocator);

    var background = try Background.create(vc, allocator);
    errdefer background.destroy(vc, allocator);
    {
        const skybox_image = try exr.helpers.Rgba2D.load(allocator, skybox_filepath);
        defer allocator.free(skybox_image.asSlice());
        _ = try background.addBackground(vc, allocator, encoder, skybox_image, Mat3.identity, "exr");
    }

    return Self {
        .world = world,
        .background = background,
        .camera = camera,
    };
}

pub fn pushDescriptors(self: *const Self, camera: u32, sensor: u32, background: u32) engine.hrtsystem.pipeline.StandardBindings {
    _ = camera;
    return engine.hrtsystem.pipeline.StandardBindings {
        .tlas = self.world.accel.tlas_handle,
        .instances = self.world.accel.instances_device.deviceSlice(),
        .world_to_instances = self.world.accel.world_to_instance_device.deviceSlice(),
        .meshes = self.world.meshes.device.deviceSlice(),
        .geometries = self.world.models.geometries_device.deviceSlice(),
        .models = self.world.models.models_device.deviceSlice(),
        .materials = self.world.materials.materials.deviceSlice(),
        .instance_powers = self.world.accel.instance_powers.deviceSlice(),
        .background_image = .{ .view = self.background.backgrounds.items[background].image.view },
        .output_image = .{ .view = self.camera.sensors.items[sensor].image.view },
    };
}

pub fn pushConstants(self: *const Self, camera: u32, sensor: u32, background: u32) engine.hrtsystem.pipeline.StandardPushConstants {
    return engine.hrtsystem.pipeline.StandardPushConstants {
        .instance_count = self.world.accel.instance_count,
        .camera = self.camera.cameras.items[camera][1],
        .aspect_ratio = self.camera.sensors.items[sensor].aspectRatio(),
        .sample_count = self.camera.sensors.items[sensor].sample_count,
        .global_volume = self.global_volume,
        .background_to_world = self.background.backgrounds.items[background].transform,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.world.destroy(vc, allocator);
    self.background.destroy(vc, allocator);
    self.camera.destroy(vc, allocator);
}
