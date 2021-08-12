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
const Image = @import("./Image.zig");
const Texture = @import("./Texture.zig");

const F32x3 = @import("./zug.zig").Vec3(f32);
const Mat4 = @import("./zug.zig").Mat4(f32);

const commands = @import("./commands.zig");
const ComputeCommands = commands.ComputeCommands;
const RenderCommands = commands.RenderCommand;

const frame_count = 2;

const Self = @This();

context: VulkanContext,
display: Display,
transfer_commands: ComputeCommands,
scene: Scene,
descriptor: Descriptor,
camera: Camera,
pipeline: Pipeline,
sample_count: u32,
skybox: Texture,

pub fn create(allocator: *std.mem.Allocator, window: *Window, initial_window_size: vk.Extent2D) !Self {
    const context = try VulkanContext.create(allocator, window);
    var transfer_commands = try ComputeCommands.create(&context);
    const display = try Display.create(&context, allocator, initial_window_size);
    try transfer_commands.transitionImageLayout(&context, display.accumulation_image.handle, .@"undefined", .general);

    const scene = try Scene.create(&context, allocator, &transfer_commands);

    const skybox = try Texture.createCubeMap(&context, &transfer_commands, "../assets/skybox/", 2048);

    const display_image_info = desc.StorageImage {
        .view = display.display_image.view,
    };

    const accmululation_image_info = desc.StorageImage {
        .view = display.accumulation_image.view,
    };

    const buffer_info = desc.StorageBuffer {
        .buffer = scene.meshes.mesh_info,
    };

    const cubemap = desc.Texture {
        .sampler = skybox.sampler,
        .view = skybox.view,
    };
    const descriptor = try Descriptor.create(&context, .{
        vk.ShaderStageFlags { .raygen_bit_khr = true },
        vk.ShaderStageFlags { .raygen_bit_khr = true },
        vk.ShaderStageFlags { .raygen_bit_khr = true },
        vk.ShaderStageFlags { .closest_hit_bit_khr = true },
        vk.ShaderStageFlags { .miss_bit_khr = true },
    }, .{
        display_image_info,
        accmululation_image_info,
        scene.tlas.handle,
        buffer_info,
        cubemap,
    });

    var camera = Camera.new(.{
        .origin = F32x3.new(7.0, 5.0, 7.0),
        .target = F32x3.new(0.0, 1.0, 0.0),
        .up = F32x3.new(0.0, 1.0, 0.0),
        .vfov = 50.0,
        .extent = initial_window_size,
    });

    const pipeline = try Pipeline.create(&context, allocator, &transfer_commands, descriptor.layout);

    var engine = Self {
        .context = context,
        .display = display,
        .transfer_commands = transfer_commands,
        .scene = scene,
        .descriptor = descriptor,
        .camera = camera,
        .pipeline = pipeline,
        .skybox = skybox,
        .sample_count = 0,
    };

    return engine;
}

pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
    self.skybox.destroy(&self.context);
    self.pipeline.destroy(&self.context);
    self.descriptor.destroy(&self.context);
    self.scene.destroy(&self.context);
    self.transfer_commands.destroy(&self.context);
    self.display.destroy(&self.context, allocator);
    self.context.destroy();
}

pub fn run(self: *Self, allocator: *std.mem.Allocator, window: *const Window) !void {
    while (!window.shouldClose()) {
        var resized = false;

        const buffer = try self.display.startFrame(&self.context, allocator, window, &self.descriptor, &resized);
        if (resized) {
            resized = false;
            try resize(self);
        }

        self.camera.push(&self.context, buffer, self.pipeline.layout);
        const sample_count_bytes = std.mem.asBytes(&self.sample_count);
        self.context.device.cmdPushConstants(buffer, self.pipeline.layout, .{ .raygen_bit_khr = true }, @sizeOf(Camera.PushInfo), sample_count_bytes.len, sample_count_bytes);

        try RenderCommands(frame_count).record(&self.context, buffer, &self.pipeline, &self.display, &self.descriptor.sets);

        try self.display.endFrame(&self.context, allocator, window, &resized);
        if (resized) {
            try resize(self);
        }

        self.sample_count += 1;
        window.pollEvents();
    }
    try self.context.device.deviceWaitIdle();
}

fn resize(self: *Self) !void {
    try self.transfer_commands.transitionImageLayout(&self.context, self.display.accumulation_image.handle, .@"undefined", .general);

    var camera_create_info = self.camera.create_info;
    camera_create_info.extent = self.display.extent;
    self.camera = Camera.new(camera_create_info);

    self.sample_count = 0;
}