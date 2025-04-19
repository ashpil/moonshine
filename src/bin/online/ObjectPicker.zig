const std = @import("std");
const vk = @import("vulkan");
const shaders = @import("shaders");

const engine = @import("engine");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;

const hrtsystem = engine.hrtsystem;
const Sensor = hrtsystem.Sensor;
const Camera = hrtsystem.CameraManager;

const F32x2 = engine.vector.Vec2(f32);

const Self = @This();

pub const Intersection = extern struct {
    instance_index: i32, // -1 if clicked background
    geometry_index: u32,
    primitive_index: u32,
    barycentrics: F32x2,

    pub fn toClickedObject(self: Intersection) ?ClickedObject {
        if (self.instance_index == -1) {
            return null;
        } else {
            return ClickedObject {
                .instance_index = @intCast(self.instance_index),
                .geometry_index = self.geometry_index,
                .primitive_index = self.primitive_index,
                .barycentrics = self.barycentrics,
            };
        }
    }
};

pub const ClickedObject = struct {
    instance_index: u32,
    geometry_index: u32,
    primitive_index: u32,
    barycentrics: F32x2,
};

pub const Pipeline = core.pipeline.Pipeline(.{
    .local_size = vk.Extent3D { .width = 1, .height = 1, .depth = 1 },
    .shader_path = "hrtsystem/input.hlsl",
    .PushConstants = extern struct {
        camera: Camera.Camera,
        aspect_ratio: f32,
        click_position: F32x2,
    },
    .PushSetBindings = struct {
        tlas: vk.AccelerationStructureKHR,
        output_image: core.pipeline.StorageImage,
        click_data: core.mem.BufferSlice(Intersection),
    },
});

buffer: core.mem.Buffer(Intersection, .{ .host_visible_bit = true, .host_coherent_bit = true }, .{ .storage_buffer_bit = true }),
pipeline: Pipeline,

encoder: Encoder,
ready_fence: vk.Fence,

pub fn create(vc: *const VulkanContext, allocator: std.mem.Allocator) !Self {
    const buffer = try core.mem.Buffer(Intersection, .{ .host_visible_bit = true, .host_coherent_bit = true }, .{ .storage_buffer_bit = true }).create(vc, 1, "object picker");
    errdefer buffer.destroy(vc);

    var pipeline = try Pipeline.create(vc, allocator, .{}, .{}, .{});
    errdefer pipeline.destroy(vc);

    var encoder = try Encoder.create(vc, "object picker");
    errdefer encoder.destroy(vc);

    const ready_fence = try vc.device.createFence(&.{
        .flags = .{},
    }, null);
    errdefer vc.device.destroyFence(ready_fence, null);

    return Self {
        .buffer = buffer,
        .pipeline = pipeline,

        .encoder = encoder,
        .ready_fence = ready_fence,
    };
}

pub fn getClickedObject(self: *Self, vc: *const VulkanContext, accel: vk.AccelerationStructureKHR, normalized_coords: F32x2, camera: Camera.Camera, sensor: Sensor) !?ClickedObject {
    // begin
    try self.encoder.begin();

    // bind pipeline + sets
    self.pipeline.recordBindPipeline(self.encoder.buffer);
    self.pipeline.recordPushDescriptors(self.encoder.buffer, Pipeline.PushSetBindings {
        .tlas = accel,
        .output_image = .{ .view = sensor.image.view },
        .click_data = self.buffer.deviceSlice(),
    });

    self.pipeline.recordPushConstants(self.encoder.buffer, .{ .camera = camera, .aspect_ratio = sensor.aspectRatio(), .click_position = normalized_coords });

    // trace rays
    self.pipeline.recordDispatchThreads1D(self.encoder.buffer, 1);

    // end
    try self.encoder.submit(vc.queue, .{ .fence = self.ready_fence });

    _ = try vc.device.waitForFences(1, @ptrCast(&self.ready_fence), vk.TRUE, std.math.maxInt(u64));
    try vc.device.resetFences(1, @ptrCast(&self.ready_fence));
    try vc.device.resetCommandPool(self.encoder.pool, .{});

    return self.buffer.hostSlice()[0].toClickedObject();
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.buffer.destroy(vc);
    self.pipeline.destroy(vc);
    self.encoder.destroy(vc);
    vc.device.destroyFence(self.ready_fence, null);
}
