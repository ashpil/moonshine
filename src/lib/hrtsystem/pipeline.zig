const shaders = @import("shaders");
const vk = @import("vulkan");
const std = @import("std");
const build_options = @import("build_options");

const engine = @import("../engine.zig");
const core = engine.core;
const Pipeline = core.pipeline.Pipeline;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const descriptor = core.descriptor;

const Camera = @import("./CameraManager.zig");
const Material = @import("./MaterialManager.zig");

const vector = engine.vector;
const F32x2 = vector.Vec2(f32);
const F32x3 = vector.Vec3(f32);
const Mat4x3 = vector.Mat4x3(f32);

pub const StandardBindings = struct {
    tlas: ?vk.AccelerationStructureKHR,
    instances: ?core.mem.BufferSlice(vk.AccelerationStructureInstanceKHR),
    world_to_instances: ?core.mem.BufferSlice(Mat4x3),
    meshes: ?core.mem.BufferSlice(engine.hrtsystem.MeshManager.Mesh.Device),
    geometries: ?core.mem.BufferSlice(engine.hrtsystem.ModelManager.Geometry.Device),
    models: ?core.mem.BufferSlice(engine.hrtsystem.ModelManager.Model.Device),
    materials: ?core.mem.BufferSlice(engine.hrtsystem.MaterialManager.Material.Device),
    instance_powers: core.mem.BufferSlice(F32x3),
    background_image: core.pipeline.CombinedImageSampler,
    output_image: core.pipeline.StorageImage,
};

pub const StandardPushConstants = extern struct {
    instance_count: u32,
    camera: Camera.Camera,
    aspect_ratio: f32,
    sample_count: u32,
    global_volume: Material.Volume = .{},
};

pub const Integrator = enum(u32) {
    direct_lighting,
    path_tracing,
    volume_path_tracing,
};

pub const StandardPipeline = Pipeline(.{
    .local_size = vk.Extent3D { .width = 8, .height = 8, .depth = 1 },
    .shader_path = "hrtsystem/main.hlsl",
    .SpecConstants = extern struct {
        integrator: Integrator = .path_tracing,
        direct_lighting_env_samples: u32 = 1,
        direct_lighting_mesh_samples: u32 = 1,
        direct_lighting_brdf_samples: u32 = 1,
        path_tracing_russian_roulette_depth: u32 = 3,
        path_tracing_env_samples_per_bounce: u32 = 1,
        path_tracing_mesh_samples_per_bounce: u32 = 1,
        volume_path_tracing_russian_roulette_depth: u32 = 3,
        volume_path_tracing_env_samples_per_bounce: u32 = 1,
        volume_path_tracing_mesh_samples_per_bounce: u32 = 1,
    },
    .PushConstants = StandardPushConstants,
    .additional_descriptor_layout_count = 2,
    .PushSetBindings = StandardBindings,
});

pub fn dispatch(pipeline: anytype, encoder: *Encoder, extent: vk.Extent2D) void {
    const width = std.math.divCeil(extent.width, 32) catch unreachable;
    const height = std.math.divCeil(extent.height, 32) catch unreachable;
    pipeline.recordDispatch(encoder.buffer, .{ .width = width, .height = height, .depth = 1 });
}