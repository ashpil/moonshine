const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const F32x3 = @import("../vector.zig").Vec3(f32);

pub const CreateInfo = struct {
    origin: F32x3,
    target: F32x3,
    up: F32x3,
    vfov: f32,
    extent: vk.Extent2D,
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
    const theta = create_info.vfov * std.math.pi / 180;
    const h = std.math.tan(theta / 2);
    const viewport_height = 2.0 * h * create_info.focus_distance;
    const viewport_width = @intToFloat(f32, create_info.extent.width) / @intToFloat(f32, create_info.extent.height) * viewport_height;

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
