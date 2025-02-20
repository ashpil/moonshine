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

const exr = engine.fileformats.exr;

const vector = @import("../vector.zig");
const F32x3 = vector.Vec3(f32);
const F32x4 = vector.Vec4(f32);
const Mat3x4 = vector.Mat3x4(f32);
const Mat3 = vector.Mat3(f32);

const Self = @This();

world: World,
background: Background,
camera: Camera,

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
        const to_gltf = Mat3x4.fromTransformTranslation(Mat3.fromRows(
            F32x3.new( 0, 1, 0),
            F32x3.new( 0, 0,-1),
            F32x3.new(-1, 0, 0),
        ), F32x3.zero);

        for (gltf.data.nodes.items) |node| {
            if (node.camera) |camera_idx| {
                const gltf_camera = gltf.data.cameras.items[camera_idx];
                const mat = Gltf.getGlobalTransform(&gltf.data, node);
                // convert to Z-up
                const transform = Mat3x4.fromRows(
                    F32x4.new(mat[0][0], mat[1][0], mat[2][0], mat[3][0]),
                    F32x4.new(mat[0][2], mat[1][2], mat[2][2], mat[3][2]),
                    F32x4.new(mat[0][1], mat[1][1], mat[2][1], mat[3][1]),
                );
                _ = try camera.appendCamera(allocator, Camera.Camera {
                    .transform = transform.mul(to_gltf),
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
            const transform = Mat3x4.fromRows(
                F32x4.new(1, 0, 0, 0),
                F32x4.new(0, 0, 1, 5), // looking at origin
                F32x4.new(0, 1, 0, 0),
            );
            _ = try camera.appendCamera(allocator, Camera.Camera {
                .transform = transform.mul(to_gltf),
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
        try background.addBackground(vc, allocator, encoder, skybox_image, "exr");
    }

    return Self {
        .world = world,
        .background = background,
        .camera = camera,
    };
}

pub fn pushDescriptors(self: *const Self, sensor: u32, background: u32) engine.hrtsystem.pipeline.StandardBindings {
    return engine.hrtsystem.pipeline.StandardBindings {
        .tlas = self.world.accel.tlas_handle,
        .instances = self.world.accel.instances_device.deviceSlice(),
        .world_to_instances = self.world.accel.world_to_instance_device.deviceSlice(),
        .meshes = self.world.meshes.device.deviceSlice(),
        .geometries = self.world.models.geometries.deviceSlice(),
        .models = self.world.models.models_device.deviceSlice(),
        .materials = self.world.materials.materials.deviceSlice(),
        .triangle_powers = self.world.accel.triangle_powers.deviceSlice(),
        .triangle_meta = self.world.accel.triangle_powers_meta.deviceSlice(),
        .geometry_to_triangle_power_offset = self.world.accel.geometry_to_triangle_power_offset.deviceSlice(),
        .emissive_triangle_count = self.world.accel.emissive_triangle_count.deviceSlice(),
        .background_rgb_image = .{ .view = self.background.data.items[background].rgb_image.view },
        .background_luminance_image = .{ .view = self.background.data.items[background].luminance_image.view },
        .output_image = .{ .view = self.camera.sensors.items[sensor].image.view },
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.world.destroy(vc, allocator);
    self.background.destroy(vc, allocator);
    self.camera.destroy(vc, allocator);
}
