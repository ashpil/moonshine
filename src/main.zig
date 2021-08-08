const std = @import("std");
const vk = @import("vulkan");

const Window = @import("./Window.zig");
const Camera = @import("./Camera.zig");
const Engine = @import("./Engine.zig");

const F32x3 = @import("./zug.zig").Vec3(f32);
const Mat4 = @import("./zug.zig").Mat4(f32);

const initial_window_size = vk.Extent2D {
    .width = 800,
    .height = 600,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    var window = try Window.create(initial_window_size);
    defer window.destroy();

    var engine = try Engine.create(allocator, &window, initial_window_size);
    defer engine.destroy(allocator);

    window.setEngine(&engine);
    window.setKeyCallback(keyCallback);

    try engine.run(allocator, &window);

    std.log.info("Program completed!.", .{});
}


fn keyCallback(window: *const Window, key: u32, action: Window.Action, engine: *Engine) void {
    _ = window;
    if (action == .repeat or action == .press) {
        var camera_create_info = engine.camera.create_info;

        var mat: Mat4 = undefined;
        if (key == 65) {
            mat = Mat4.fromAxisAngle(-0.1, F32x3.new(0.0, 1.0, 0.0));
        } else if (key == 68) {
            mat = Mat4.fromAxisAngle(0.1, F32x3.new(0.0, 1.0, 0.0));
        } else if (key == 83) {
            const target_dir = camera_create_info.origin.sub(camera_create_info.target);
            const axis = camera_create_info.up.cross(target_dir).unit();
            if (F32x3.new(0.0, -1.0, 0.0).dot(target_dir.unit()) > 0.99) {
                return;
            }
            mat = Mat4.fromAxisAngle(0.1, axis);
        } else if (key == 87) {
            const target_dir = camera_create_info.origin.sub(camera_create_info.target);
            const axis = camera_create_info.up.cross(target_dir).unit();
            if (F32x3.new(0.0, 1.0, 0.0).dot(target_dir.unit()) > 0.99) {
                return;
            }
            mat = Mat4.fromAxisAngle(-0.1, axis);
        } else return;

        camera_create_info.origin = mat.mul_point(camera_create_info.origin.sub(camera_create_info.target)).add(camera_create_info.target);

        engine.camera = Camera.new(camera_create_info);

        engine.sample_count = 0;
    }
}