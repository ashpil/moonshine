const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const Window = @import("./Window.zig");
const Pipeline = @import("./Pipeline.zig");
const Scene = @import("./Scene.zig");
const desc = @import("./descriptor.zig");
const Descriptor = desc.Descriptor(frame_count);
const Display = @import("./display.zig").Display(frame_count);
const Camera = @import("./Camera.zig");
const Image = @import("./images.zig").Images(1);

const F32x3 = @import("./zug.zig").Vec3(f32);
const Mat4 = @import("./zug.zig").Mat4(f32);

const commands = @import("./commands.zig");
const ComputeCommands = commands.ComputeCommands;
const RenderCommands = commands.RenderCommand;

const frame_count = 2;

const initial_window_size = vk.Extent2D {
    .width = 800,
    .height = 600,
};

const Self = @This();

window: Window,

context: VulkanContext,
display: Display,
transfer_commands: ComputeCommands,
scene: Scene,
descriptor: Descriptor,
camera: Camera,
pipeline: Pipeline,
frame_count: u32,

skybox: Image,
sampler: vk.Sampler,

pub fn create(allocator: *std.mem.Allocator) !Self {

    const window = try Window.create(initial_window_size);

    const context = try VulkanContext.create(allocator, &window);
    var transfer_commands = try ComputeCommands.create(&context);
    const display = try Display.create(&context, allocator, initial_window_size);
    try transfer_commands.transitionImageLayout(&context, display.accumulation_image.images[0], .@"undefined", .general);

    const scene = try Scene.create(&context, allocator, &transfer_commands);

    const skybox = try Image.createTexture(&context, .{
        .{
            .filepath = "../../assets/textures/skybox.dds",
        }
    }, &transfer_commands);

    const sampler = try Image.createSampler(&context);

    const display_image_info = desc.StorageImage {
        .view = display.display_image.views[0],
    };

    const accmululation_image_info = desc.StorageImage {
        .view = display.accumulation_image.views[0],
    };

    const buffer_info = desc.StorageBuffer {
        .buffer = scene.meshes.mesh_info,
    };

    const cubemap = desc.Texture {
        .sampler = sampler,
        .view = skybox.views[0],
    };

    const sampler_info = desc.Sampler {
        .sampler = sampler,
    };

    const color_textures = desc.TextureArray(scene.albedo_textures.views.len) {
        .views = scene.albedo_textures.views,
    };
    const roughness_textures = desc.TextureArray(scene.albedo_textures.views.len) {
        .views = scene.roughness_textures.views,
    };
    const normal_textures = desc.TextureArray(scene.albedo_textures.views.len) {
        .views = scene.normal_textures.views,
    };
    const descriptor = try Descriptor.create(&context, .{
        vk.ShaderStageFlags { .raygen_bit_khr = true },
        vk.ShaderStageFlags { .raygen_bit_khr = true },
        vk.ShaderStageFlags { .raygen_bit_khr = true },
        vk.ShaderStageFlags { .closest_hit_bit_khr = true },
        vk.ShaderStageFlags { .miss_bit_khr = true },
        vk.ShaderStageFlags { .closest_hit_bit_khr = true },
        vk.ShaderStageFlags { .closest_hit_bit_khr = true },
        vk.ShaderStageFlags { .closest_hit_bit_khr = true },
        vk.ShaderStageFlags { .closest_hit_bit_khr = true },
    }, .{
        display_image_info,
        accmululation_image_info,
        scene.tlas.handle,
        buffer_info,
        cubemap,
        sampler_info,
        color_textures,
        roughness_textures,
        normal_textures,
    });

    var camera = Camera.new(.{
        .origin = F32x3.new(0.4, 0.3, -0.4),
        .target = F32x3.new(0.0, 0.0, 0.0),
        .up = F32x3.new(0.0, 1.0, 0.0),
        .vfov = 50.0,
        .extent = initial_window_size,
    });

    const pipeline = try Pipeline.create(&context, allocator, &transfer_commands, descriptor.layout);

    var engine = Self {
        .window = window,
        .context = context,
        .display = display,
        .transfer_commands = transfer_commands,
        .scene = scene,
        .descriptor = descriptor,
        .camera = camera,
        .pipeline = pipeline,
        .skybox = skybox,
        .sampler = sampler,
        .frame_count = 0,
    };
    return engine;
}

pub fn setCallbacks(self: *Self) void {
    self.window.setEngine(self);
    self.window.setKeyCallback(keyCallback);
}

fn keyCallback(window: *const Window, key: u32, action: Window.Action, engine: *Self) void {
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

        engine.frame_count = 0;
    }
}

pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
    self.context.device.destroySampler(self.sampler, null);
    self.skybox.destroy(&self.context);
    self.pipeline.destroy(&self.context);
    self.descriptor.destroy(&self.context);
    self.scene.destroy(&self.context);
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
        const frame_count_bytes = std.mem.asBytes(&self.frame_count);
        self.context.device.cmdPushConstants(buffer, self.pipeline.layout, .{ .raygen_bit_khr = true }, @sizeOf(Camera.PushInfo), frame_count_bytes.len, frame_count_bytes);

        try RenderCommands(frame_count).record(&self.context, buffer, &self.pipeline, &self.display, &self.descriptor.sets);

        try self.display.endFrame(&self.context, allocator, &self.window, &resized);
        if (resized) {
            try resize(self);
        }

        if (!resized) {
            self.frame_count += 1;
        }
        self.window.pollEvents();
    }
    try self.context.device.deviceWaitIdle();
}

fn resize(self: *Self) !void {
    try self.transfer_commands.transitionImageLayout(&self.context, self.display.accumulation_image.images[0], .@"undefined", .general);

    var camera_create_info = self.camera.create_info;
    camera_create_info.extent = self.display.extent;
    self.camera = Camera.new(camera_create_info);

    self.frame_count = 0;
}