const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const Window = @import("./Window.zig");
const Swapchain = @import("./Swapchain.zig");
const Pipeline = @import("./Pipeline.zig");
const Scene = @import("./Scene.zig");
const Descriptor = @import("./descriptor.zig").Descriptor;
const Image = @import("./Image.zig");
const Display = @import("./display.zig").Display;
const Camera = @import("./Camera.zig");
const F32x3 = @import("./zug.zig").Vec3(f32);
const Mat4 = @import("./zug.zig").Mat4(f32);

const commands = @import("./commands.zig");
const ComputeCommands = commands.ComputeCommands;
const RenderCommands = commands.RenderCommand;

const initial_window_size = vk.Extent2D {
    .width = 800,
    .height = 600,
};

const frame_count = 2;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    var window = try Window.create(initial_window_size);
    defer window.destroy();

    var context = try VulkanContext.create(allocator, &window);
    defer context.destroy();

    var display = try Display(frame_count).create(&context, allocator, initial_window_size);
    defer display.destroy(&context, allocator);

    var transfer_commands = try ComputeCommands.create(&context);
    defer transfer_commands.destroy(&context);

    var scene = try Scene.create(&context, allocator, &transfer_commands);
    defer scene.destroy(&context);

    const image_info = vk.DescriptorImageInfo {
        .sampler = .null_handle,
        .image_view = display.storage_image.view,
        .image_layout = vk.ImageLayout.general,
    };

    const buffer_info = vk.DescriptorBufferInfo {
        .range = vk.WHOLE_SIZE,
        .offset = 0,
        .buffer = scene.meshes.mesh_info,
    };
    var sets = try Descriptor(frame_count).create(&context, .{
        vk.ShaderStageFlags { .raygen_bit_khr = true },
        vk.ShaderStageFlags { .raygen_bit_khr = true },
        vk.ShaderStageFlags { .closest_hit_bit_khr = true },
    }, .{
        image_info,
        scene.tlas.handle,
        buffer_info,
    });
    defer sets.destroy(&context);

    var camera = Camera.new(.{
        .origin = F32x3.new(7.0, 5.0, 7.0),
        .target = F32x3.new(0.0, 1.0, 0.0),
        .up = F32x3.new(0.0, 1.0, 0.0),
        .vfov = 40.0,
        .extent = initial_window_size,
    });

    window.setUserPointer(&camera);
    window.setKeyCallback(keyCallback);
    
    var pipeline = try Pipeline.create(&context, allocator, &transfer_commands, sets.layout);
    defer pipeline.destroy(&context);

    while (!window.shouldClose()) {
        const buffer = try display.startFrame(&context, allocator, &window, &sets, &camera);
        camera.push(&context, buffer, pipeline.layout);
        try RenderCommands(frame_count).record(&context, buffer, &pipeline, &display, &sets.sets);
        try display.endFrame(&context, allocator, &window, &camera);
        window.pollEvents();
    }

    try context.device.deviceWaitIdle();

    std.log.info("Program completed!.", .{});
}

fn keyCallback(window: *const Window, key: u32, action: Window.Action, data: *c_void) void {
    _ = window;
    if (action == .repeat or action == .press) {
        var camera = @ptrCast(*Camera, @alignCast(@alignOf(Camera), data));
        var camera_create_info = camera.create_info;

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

        camera.* = Camera.new(camera_create_info);
    }
}
