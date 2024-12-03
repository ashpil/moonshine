const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;

const Sensor = core.Sensor;

const Mat3x4 = engine.vector.Mat3x4(f32);

pub const Lens = extern struct {
    transform: Mat3x4,
    vfov: f32, // radians
    aperture: f32,
    focus_distance: f32,
};

sensors: std.ArrayListUnmanaged(Sensor) = .{},
lenses: std.ArrayListUnmanaged(Lens) = .{},

const Self = @This();

pub const SensorHandle = u32;
pub fn appendSensor(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, extent: vk.Extent2D) !SensorHandle {
    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&buf, "render {}", .{self.sensors.items.len});

    try self.sensors.append(allocator, try Sensor.create(vc, extent, name));
    return @intCast(self.sensors.items.len - 1);
}

pub const LensHandle = u32;
pub fn appendLens(self: *Self, allocator: std.mem.Allocator, lens: Lens) !LensHandle {
    try self.lenses.append(allocator, lens);
    return @intCast(self.lenses.items.len - 1);
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
    self.sensors.deinit(allocator);
    self.lenses.deinit(allocator);
}
