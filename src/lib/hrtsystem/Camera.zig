const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;

const Sensor = core.Sensor;

const vector = @import("../vector.zig");
const F32x2 = vector.Vec2(f32);
const F32x3 = vector.Vec3(f32);
const F32x4 = vector.Vec4(f32);
const Mat3x4 = vector.Mat3x4(f32);

pub const Lens = extern struct {
    origin: F32x3,
    forward: F32x3,
    up: F32x3,
    vfov: f32, // radians
    aperture: f32,
    focus_distance: f32,

    pub fn fromGltf(gltf: Gltf) !Lens {
        // just use first camera found in nodes, if none found, use an arbitrary default
        const yfov, const transform = for (gltf.data.nodes.items) |node| {
            if (node.camera) |camera| {
                const yfov = gltf.data.cameras.items[camera].type.perspective.yfov;
                const mat = Gltf.getGlobalTransform(&gltf.data, node);
                // convert to Z-up
                const transform = Mat3x4.new(
                    F32x4.new(mat[0][0], mat[1][0], mat[2][0], mat[3][0]),
                    F32x4.new(mat[0][2], mat[1][2], mat[2][2], mat[3][2]),
                    F32x4.new(mat[0][1], mat[1][1], mat[2][1], mat[3][1]),
                );
                break .{ yfov, transform };
            }
        } else .{ std.math.pi / 6.0, Mat3x4.new(
            F32x4.new(1, 0, 0, 0),
            F32x4.new(0, 0, 1, 5), // looking at origin
            F32x4.new(0, 1, 0, 0),
        ) };

        return Lens {
            .origin = transform.mulPoint(F32x3.new(0.0, 0.0, 0.0)),
            .forward = transform.mulVector(F32x3.new(0.0, 0.0, -1.0)).unit(),
            .up = transform.mulVector(F32x3.new(0.0, 1.0, 0.0)).unit(),
            .vfov = yfov,
            .aperture = 0.0,
            .focus_distance = 1.0,
        };
    }

    // should correspond to GPU-side generateRay
    pub fn directionFromUv(self: Lens, uv: F32x2, aspect: f32) F32x3 {
        const w = self.forward;
        const u = self.up.cross(w).unit();
        const v = u.cross(w);

        const h = std.math.tan(self.vfov / 2);
        const viewport_height = 2 * h * self.focus_distance;
        const viewport_width = aspect * viewport_height;

        const horizontal = u.scale(viewport_width);
        const vertical = v.scale(viewport_height);

        const lower_left_corner = self.origin.sub(horizontal.scale(1.0 / 2.0)).sub(vertical.scale(1.0 / 2.0)).add(w.scale(self.focus_distance));

        return (lower_left_corner.add(horizontal.scale(uv.x)).add(vertical.scale(uv.y)).sub(self.origin)).unit();
    }
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
