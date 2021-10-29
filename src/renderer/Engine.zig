const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const Window = @import("./Window.zig");
const Pipeline = @import("./Pipeline.zig");
const desc = @import("./descriptor.zig");
const Descriptor = desc.Descriptor(frames_in_flight);
const Display = @import("./display.zig").Display(frames_in_flight);
const Camera = @import("./Camera.zig");
const Images = @import("./Images.zig");

const F32x3 = @import("../utils/zug.zig").Vec3(f32);
const Mat4 = @import("../utils/zug.zig").Mat4(f32);

const commands = @import("./commands.zig");
const ComputeCommands = commands.ComputeCommands;
const RenderCommands = commands.RenderCommand;

const Scene = @import("../logic/Scene.zig"); // TODO: create scene struct in renderer, decouple chess logic from scene

const frames_in_flight = 2;

const initial_window_size = vk.Extent2D {
    .width = 800,
    .height = 600,
};

const Self = @This();

window: Window,

context: VulkanContext,
display: Display,
transfer_commands: ComputeCommands,
descriptor: Descriptor,
camera: Camera,
pipeline: Pipeline,
num_accumulted_frames: u32,

sampler: vk.Sampler,

pub fn create(comptime max_textures: comptime_int, allocator: *std.mem.Allocator) !Self {

    const window = try Window.create(initial_window_size);

    const context = try VulkanContext.create(allocator, &window);
    var transfer_commands = try ComputeCommands.create(&context);
    const display = try Display.create(&context, allocator, initial_window_size);
    // todo: why transition here?
    try transfer_commands.transitionImageLayout(&context, display.accumulation_image.data.items(.image)[0], .@"undefined", .general);

    const descriptor = try Descriptor.create(&context, [10]desc.BindingInfo {
        .{
            .stage_flags = .{ .raygen_bit_khr = true },
            .descriptor_type = .storage_image,
            .count = 1,
        },
        .{
            .stage_flags = .{ .raygen_bit_khr = true },
            .descriptor_type = .storage_image,
            .count = 1,
        },
        .{
            .stage_flags = .{ .closest_hit_bit_khr = true },
            .descriptor_type = .sampler,
            .count = 1,
        },
        .{
            .stage_flags = .{ .raygen_bit_khr = true },
            .descriptor_type = .acceleration_structure_khr,
            .count = 1,
        },
        .{
            .stage_flags = .{ .miss_bit_khr = true },
            .descriptor_type = .combined_image_sampler,
            .count = 1,
        },
        .{
            .stage_flags = .{ .closest_hit_bit_khr = true },
            .descriptor_type = .storage_buffer,
            .count = 1,
        },
        .{
            .stage_flags = .{ .closest_hit_bit_khr = true },
            .descriptor_type = .storage_buffer,
            .count = 1,
        },
        .{
            .stage_flags = .{ .closest_hit_bit_khr = true },
            .descriptor_type = .sampled_image,
            .count = max_textures,
        },
        .{
            .stage_flags = .{ .closest_hit_bit_khr = true },
            .descriptor_type = .sampled_image,
            .count = max_textures,
        },
        .{
            .stage_flags = .{ .closest_hit_bit_khr = true },
            .descriptor_type = .sampled_image,
            .count = max_textures,
        },
    });

    comptime var frames: [frames_in_flight]u32 = undefined;
    comptime for (frames) |_, i| {
        frames[i] = i;
    };

    comptime var sets: [3]u32 = undefined;
    comptime for (sets) |_, i| {
        sets[i] = i;
    };

    const sampler = try Images.createSampler(&context);

    const display_image_info = desc.StorageImage {
        .view = display.display_image.data.items(.view)[0],
    };

    const accmululation_image_info = desc.StorageImage {
        .view = display.accumulation_image.data.items(.view)[0],
    };

    const sampler_info = desc.Sampler {
        .sampler = sampler,
    };

    try descriptor.write(&context, allocator, sets, frames, .{
        display_image_info,
        accmululation_image_info,
        sampler_info,
    });

    const camera_origin = F32x3.new(0.4, 0.3, -0.4);
    const camera_target = F32x3.new(0.0, 0.0, 0.0);

    var camera = Camera.new(.{
        .origin = camera_origin,
        .target = camera_target,
        .up = F32x3.new(0.0, 1.0, 0.0),
        .vfov = 40.0,
        .extent = initial_window_size,
        .aperture = 0.007,
        .focus_distance = camera_origin.sub(camera_target).length(),
    });

    const pipeline = try Pipeline.create(&context, allocator, &transfer_commands, descriptor.layout);

    return Self {
        .window = window,
        .context = context,
        .display = display,
        .transfer_commands = transfer_commands,
        .descriptor = descriptor,
        .camera = camera,
        .pipeline = pipeline,
        .sampler = sampler,
        .num_accumulted_frames = 0,
    };
}

pub fn setScene(self: *Self, allocator: *std.mem.Allocator, scene: *const Scene) !void {

    comptime var frames: [frames_in_flight]u32 = undefined;
    comptime for (frames) |_, i| {
        frames[i] = i;
    };

    comptime var sets: [7]u32 = undefined;
    comptime for (sets) |_, i| {
        sets[i] = i + 3;
    };

    const background = desc.Texture {
        .sampler = self.sampler,
        .view = scene.background.data.items(.view)[0],
    };
    const mesh_info = desc.StorageBuffer {
        .buffer = scene.meshes.mesh_info,
    };
    const materials_info = desc.StorageBuffer {
        .buffer = scene.materials_buffer,
    };
    const color_textures = desc.TextureArray {
        .views = scene.color_textures.data.items(.view),
    };
    const roughness_textures = desc.TextureArray {
        .views = scene.roughness_textures.data.items(.view),
    };
    const normal_textures = desc.TextureArray {
        .views = scene.normal_textures.data.items(.view),
    };

    try self.descriptor.write(&self.context, allocator, sets, frames, .{
        scene.accel.tlas_handle,
        background,
        mesh_info,
        materials_info,
        color_textures,
        roughness_textures,
        normal_textures,
    });
}

pub fn setCallbacks(self: *Self) void {
    self.window.setEngine(self);
    self.window.setKeyCallback(keyCallback);
}

fn keyCallback(window: *const Window, key: u32, action: Window.Action, engine: *Self) void {
    _ = window;
    if (action == .repeat or action == .press) {
        var camera_create_info = engine.camera.create_info;
        if (key == 65 or key == 68 or key == 83 or key == 87) {
            const move_amount = 1.0 / 18.0;
            var mat: Mat4 = undefined;
            if (key == 65) {
                mat = Mat4.fromAxisAngle(-move_amount, F32x3.new(0.0, 1.0, 0.0));
            } else if (key == 68) {
                mat = Mat4.fromAxisAngle(move_amount, F32x3.new(0.0, 1.0, 0.0));
            } else if (key == 83) {
                const target_dir = camera_create_info.origin.sub(camera_create_info.target);
                const axis = camera_create_info.up.cross(target_dir).unit();
                if (F32x3.new(0.0, -1.0, 0.0).dot(target_dir.unit()) > 0.99) {
                    return;
                }
                mat = Mat4.fromAxisAngle(move_amount, axis);
            } else if (key == 87) {
                const target_dir = camera_create_info.origin.sub(camera_create_info.target);
                const axis = camera_create_info.up.cross(target_dir).unit();
                if (F32x3.new(0.0, 1.0, 0.0).dot(target_dir.unit()) > 0.99) {
                    return;
                }
                mat = Mat4.fromAxisAngle(-move_amount, axis);
            } else unreachable;

            camera_create_info.origin = mat.mul_point(camera_create_info.origin.sub(camera_create_info.target)).add(camera_create_info.target);
        } else if (key == 70 and camera_create_info.aperture > 0.0) {
            camera_create_info.aperture -= 0.0005;
        } else if (key == 82) {
            camera_create_info.aperture += 0.0005;
        } else if (key == 81) {
            camera_create_info.focus_distance -= 0.01;
        } else if (key == 69) {
            camera_create_info.focus_distance += 0.01;
        } else return;

        engine.camera = Camera.new(camera_create_info);

        engine.num_accumulted_frames = 0;
    }
}

pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
    self.context.device.destroySampler(self.sampler, null);
    self.pipeline.destroy(&self.context);
    self.descriptor.destroy(&self.context);
    self.transfer_commands.destroy(&self.context);
    self.display.destroy(&self.context, allocator);
    self.context.destroy();
    self.window.destroy();
}

pub fn run(self: *Self, allocator: *std.mem.Allocator) !void {
    while (!self.window.shouldClose()) {
        var resized = false;

        const buffer = try self.display.startFrame(&self.context, allocator, &self.window, &self.descriptor, &resized);
        if (resized) {
            resized = false;
            try resize(self);
        }

        self.camera.push(&self.context, buffer, self.pipeline.layout);
        const num_accumulted_frames_bytes = std.mem.asBytes(&self.num_accumulted_frames);
        self.context.device.cmdPushConstants(buffer, self.pipeline.layout, .{ .raygen_bit_khr = true }, @sizeOf(Camera.PushInfo), num_accumulted_frames_bytes.len, num_accumulted_frames_bytes);

        try RenderCommands(frames_in_flight).record(&self.context, buffer, &self.pipeline, &self.display, &self.descriptor.sets);

        try self.display.endFrame(&self.context, allocator, &self.window, &resized);
        if (resized) {
            try resize(self);
        }

        if (!resized) {
            self.num_accumulted_frames += 1;
        }
        self.window.pollEvents();
    }
    try self.context.device.deviceWaitIdle();
}

fn resize(self: *Self) !void {
    // todo: or here
    try self.transfer_commands.transitionImageLayout(&self.context, self.display.accumulation_image.data.items(.image)[0], .@"undefined", .general);

    var camera_create_info = self.camera.create_info;
    camera_create_info.extent = self.display.extent;
    self.camera = Camera.new(camera_create_info);

    self.num_accumulted_frames = 0;
}