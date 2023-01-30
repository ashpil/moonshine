const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");

const VulkanContext = @import("./VulkanContext.zig");
const vector = @import("../vector.zig");
const F32x3 = vector.Vec3(f32);
const F32x4 = vector.Vec4(f32);
const Mat3x4 = vector.Mat3x4(f32);

pub const CreateInfo = struct {
    origin: F32x3,
    target: F32x3,
    up: F32x3,
    vfov: f32, // radians
    aspect: f32, // width / height
    aperture: f32,
    focus_distance: f32,
};

pub const Desc = struct {
    origin: F32x3,
    lower_left_corner: F32x3,
    horizontal: F32x3,
    vertical: F32x3,
};

pub const BlurDesc = struct {
    u: F32x3,
    v: F32x3,
    lens_radius: f32,
};

desc: Desc,
blur_desc: BlurDesc,

const Self = @This();

pub fn new(create_info: CreateInfo) Self {
    const h = std.math.tan(create_info.vfov / 2);
    const viewport_height = 2.0 * h * create_info.focus_distance;
    const viewport_width = create_info.aspect * viewport_height;

    const w = create_info.origin.sub(create_info.target).unit();
    const u = create_info.up.cross(w).unit();
    const v = w.cross(u);

    const horizontal = u.mul_scalar(viewport_width);
    const vertical = v.mul_scalar(viewport_height);

    const desc = Desc {
        .origin = create_info.origin,
        .horizontal = horizontal,
        .vertical = vertical,
        .lower_left_corner = create_info.origin.sub(horizontal.div_scalar(2.0)).sub(vertical.div_scalar(2.0)).sub(w.mul_scalar(create_info.focus_distance)),
    };

    const blur_desc = BlurDesc {
        .u = u,
        .v = v,
        .lens_radius = create_info.aperture / 2,
    };

    return Self {
        .desc = desc,
        .blur_desc = blur_desc,
    };
}

pub fn fromGlb(allocator: std.mem.Allocator, path: []const u8) !Self {
    var gltf = Gltf.init(allocator);
    defer gltf.deinit();

    const buffer = try std.fs.cwd().readFileAlloc(
        allocator,
        path,
        std.math.maxInt(usize),
    );
    defer allocator.free(buffer);
    try gltf.parse(buffer);

    // just use first camera found in nodes
    const gltf_camera_node = for (gltf.data.nodes.items) |node| {
        if (node.camera) |camera| break .{ gltf.data.cameras.items[camera], node };
    } else return error.NoCameraInGlb;
    
    const gltf_camera = gltf_camera_node[0];
    const transform = blk: {
        const mat = Gltf.getGlobalTransform(&gltf.data, gltf_camera_node[1]);
        break :blk Mat3x4.new(
            F32x4.new(mat[0][0], mat[1][0], mat[2][0], mat[3][0]),
            F32x4.new(mat[0][1], mat[1][1], mat[2][1], mat[3][1]),
            F32x4.new(mat[0][2], mat[1][2], mat[2][2], mat[3][2]),
        );
    };

    return Self.new(.{
        .origin = transform.mul_point(F32x3.new(0.0, 0.0, 0.0)),
        .target = transform.mul_point(F32x3.new(0.0, 0.0, -1.0)),
        .up = transform.mul_vec(F32x3.new(0.0, 1.0, 0.0)),
        .vfov = gltf_camera.type.perspective.yfov,
        .aspect = gltf_camera.type.perspective.aspect_ratio,
        .aperture = 0.0,
        .focus_distance = 1.0,
    });
}