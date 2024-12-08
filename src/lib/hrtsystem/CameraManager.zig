const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;

const Sensor = engine.hrtsystem.Sensor;

const Mat3x4 = engine.vector.Mat3x4(f32);

pub const Model = enum(u32) {
    thin_lens,
    orthographic,
};

pub const ThinLens = extern struct {
    vfov: f32 = std.math.pi / 4.0,
    aperture: f32 = 0,
    focus_distance: f32 = 1,
};

pub const Orthographic = extern struct {
    vscale: f32 = 1,
};

// store camera models as a struct rather than a tagged union because:
// 1. this way in interactive modes states of non-selected is saved
// 2. can pass to spirv directly
pub const Camera = extern struct {
    transform: Mat3x4 = Mat3x4.identity,
    model: Model = .thin_lens,
    thin_lens: ThinLens = .{},
    orthographic: Orthographic = .{},
};

sensors: std.ArrayListUnmanaged(Sensor) = .{},
cameras: std.ArrayListUnmanaged(std.meta.Tuple(&.{[:0]const u8, Camera })) = .{},

const Self = @This();

pub const SensorHandle = u32;
pub fn appendSensor(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, extent: vk.Extent2D) !SensorHandle {
    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&buf, "render {}", .{self.sensors.items.len});

    try self.sensors.append(allocator, try Sensor.create(vc, extent, name));
    return @intCast(self.sensors.items.len - 1);
}

pub const CameraHandle = u32;
pub fn appendCamera(self: *Self, allocator: std.mem.Allocator, lens: Camera, name: [:0]const u8) !CameraHandle {
    try self.cameras.append(allocator, .{name, lens});
    return @intCast(self.cameras.items.len - 1);
}

pub fn clearAllSensors(self: *Self) void {
    for (self.sensors.items) |*sensor| {
        sensor.clear();
    }
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    for (self.sensors.items) |*sensor| {
        sensor.destroy(vc);
    }
    for (self.cameras.items) |*camera| {
        allocator.free(camera[0]);
    }
    self.sensors.deinit(allocator);
    self.cameras.deinit(allocator);
}
