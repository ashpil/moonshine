const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const VkAllocator = core.Allocator;
const Commands = core.Commands;

const Sensor = core.Sensor;
const DescriptorLayout = Sensor.DescriptorLayout;
const ImageManager = core.ImageManager;

const vector = @import("../vector.zig");
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

    pub fn fromGlb(gltf: Gltf) !Lens {
        // just use first camera found in nodes
        const gltf_camera_node = for (gltf.data.nodes.items) |node| {
            if (node.camera) |camera| break .{ gltf.data.cameras.items[camera], node };
        } else return error.NoCameraInGlb;

        const gltf_camera = gltf_camera_node[0];
        const transform = blk: {
            const mat = Gltf.getGlobalTransform(&gltf.data, gltf_camera_node[1]);
            // convert to Z-up
            break :blk Mat3x4.new(
                F32x4.new(mat[0][0], mat[1][0], mat[2][0], mat[3][0]),
                F32x4.new(mat[0][2], mat[1][2], mat[2][2], mat[3][2]),
                F32x4.new(mat[0][1], mat[1][1], mat[2][1], mat[3][1]),
            );
        };

        return Lens {
            .origin = transform.mul_point(F32x3.new(0.0, 0.0, 0.0)),
            .forward = transform.mul_vec(F32x3.new(0.0, 0.0, -1.0)).unit(),
            .up = transform.mul_vec(F32x3.new(0.0, 1.0, 0.0)),
            .vfov = gltf_camera.type.perspective.yfov,
            .aperture = 0.0,
            .focus_distance = 1.0,
        };
    }
};

sensors: std.ArrayListUnmanaged(Sensor),
lenses: std.ArrayListUnmanaged(Lens),
descriptor_layout: DescriptorLayout,

const Self = @This();

pub fn create(vc: *const VulkanContext) !Self {
    var descriptor_layout = try DescriptorLayout.create(vc, 1, .{}); // todo: pass in max sets from somewhere
    errdefer descriptor_layout.destroy(vc);
    return Self {
        .sensors = .{},
        .lenses = .{},
        .descriptor_layout = descriptor_layout,
    };
}

pub const SensorHandle = u32;
pub fn appendSensor(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, extent: vk.Extent2D) !SensorHandle {
    try self.sensors.append(allocator, try Sensor.create(vc, vk_allocator, &self.descriptor_layout, extent));
    return @intCast(self.sensors.items.len - 1);
}

pub const LensHandle = u32;
pub fn appendLens(self: *Self, allocator: std.mem.Allocator, lens: Lens) !LensHandle {
    try self.lenses.append(allocator, lens);
    return @intCast(self.lenses.items.len - 1);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    for (self.sensors.items) |*sensor| {
        sensor.destroy(vc);
    }
    self.sensors.deinit(allocator);
    self.lenses.deinit(allocator);
    self.descriptor_layout.destroy(vc);
}
