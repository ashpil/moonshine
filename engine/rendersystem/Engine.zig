const std = @import("std");
const vk = @import("vulkan");
const shaders = @import("shaders");

const VulkanContext = @import("./VulkanContext.zig");
const Window = @import("../Window.zig");
const Pipeline = @import("./Pipeline.zig");
const descriptor = @import("./descriptor.zig");
const SceneDescriptorLayout = descriptor.SceneDescriptorLayout;
const BackgroundDescriptorLayout = descriptor.BackgroundDescriptorLayout;
const OutputDescriptorLayout = descriptor.OutputDescriptorLayout;
const Display = @import("./display.zig").Display(frames_in_flight);
const Camera = @import("./Camera.zig");

const F32x3 = @import("../vector.zig").Vec3(f32);

const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const Scene = @import("./Scene.zig");

const frames_in_flight = 2;

const Self = @This();

context: VulkanContext,
display: Display,
commands: Commands,
scene_descriptor_layout: SceneDescriptorLayout,
background_descriptor_layout: BackgroundDescriptorLayout,
output_descriptor_layout: OutputDescriptorLayout,
camera_create_info: Camera.CreateInfo,
camera: Camera,
pipeline: Pipeline,
num_accumulted_frames: u32,
allocator: VkAllocator,

pub fn create(allocator: std.mem.Allocator, window: *const Window, app_name: [*:0]const u8) !Self {

    const initial_window_size = window.getExtent();

    const context = try VulkanContext.create(.{ .allocator = allocator, .window = window, .app_name = app_name });
    var vk_allocator = try VkAllocator.create(&context, allocator);

    const scene_descriptor_layout = try SceneDescriptorLayout.create(&context, 1, null);
    const background_descriptor_layout = try BackgroundDescriptorLayout.create(&context, 1, null);
    const output_descriptor_layout = try OutputDescriptorLayout.create(&context, frames_in_flight, null);

    var commands = try Commands.create(&context);
    const display = try Display.create(&context, &vk_allocator, allocator, &commands, &output_descriptor_layout, initial_window_size);

    const camera_origin = F32x3.new(0.6, 0.5, -0.6);
    const camera_target = F32x3.new(0.0, 0.0, 0.0);
    const camera_create_info = .{
        .origin = camera_origin,
        .target = camera_target,
        .up = F32x3.new(0.0, 1.0, 0.0),
        .vfov = 35.0,
        .extent = initial_window_size,
        .aperture = 0.007,
        .focus_distance = camera_origin.sub(camera_target).length(),
    };
    const camera = Camera.new(camera_create_info);

    const pipeline = try Pipeline.createStandardPipeline(&context, &vk_allocator, allocator, &commands, &scene_descriptor_layout, &background_descriptor_layout, &output_descriptor_layout);

    return Self {
        .context = context,
        .display = display,
        .commands = commands,
        .scene_descriptor_layout = scene_descriptor_layout,
        .background_descriptor_layout = background_descriptor_layout,
        .output_descriptor_layout = output_descriptor_layout,
        .camera_create_info = camera_create_info,
        .camera = camera,
        .pipeline = pipeline,
        .num_accumulted_frames = 0,

        .allocator = vk_allocator,
    };
}

pub fn setScene(self: *Self, scene: *const Scene, buffer: vk.CommandBuffer) void {
    self.context.device.cmdBindDescriptorSets(buffer, .ray_tracing_khr, self.pipeline.layout, 0, 3, &[_]vk.DescriptorSet { scene.descriptor_set, scene.background.descriptor_set, self.display.frames[self.display.frame_index].set }, 0, undefined);
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.allocator.destroy(&self.context, allocator);
    self.scene_descriptor_layout.destroy(&self.context);
    self.background_descriptor_layout.destroy(&self.context);
    self.output_descriptor_layout.destroy(&self.context);
    self.pipeline.destroy(&self.context);
    self.commands.destroy(&self.context);
    self.display.destroy(&self.context, allocator);
    self.context.destroy();
}

pub fn startFrame(self: *Self, window: *const Window, allocator: std.mem.Allocator) !vk.CommandBuffer {
    var resized = false;

    const buffer = try self.display.startFrame(&self.context, &self.allocator, allocator, &self.commands, window, &resized);
    if (resized) {
        resized = false;
        try resize(self);
    }

    return buffer;
}

pub fn recordFrame(self: *Self, buffer: vk.CommandBuffer) !void {
    // bind our stuff
    self.context.device.cmdBindPipeline(buffer, .ray_tracing_khr, self.pipeline.handle);
    
    // push our stuff
    const bytes = std.mem.asBytes(&.{self.camera.desc, self.camera.blur_desc, self.num_accumulted_frames});
    self.context.device.cmdPushConstants(buffer, self.pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

    // trace our stuff
    const callable_table = vk.StridedDeviceAddressRegionKHR {
        .device_address = 0,
        .stride = 0,
        .size = 0,
    };
    self.context.device.cmdTraceRaysKHR(buffer, &self.pipeline.sbt.getRaygenSBT(), &self.pipeline.sbt.getMissSBT(), &self.pipeline.sbt.getHitSBT(), &callable_table, self.display.extent.width, self.display.extent.height, 1);
}

pub fn endFrame(self: *Self, window: *const Window, allocator: std.mem.Allocator) !void {
    var resized = false;
    try self.display.endFrame(&self.context, &self.allocator, allocator, &self.commands, window, &resized);
    if (resized) {
        try resize(self);
    }

    if (!resized) {
        self.num_accumulted_frames += 1;
    }
}

fn resize(self: *Self) !void {
    self.camera_create_info.extent = self.display.extent;
    self.camera = Camera.new(self.camera_create_info);

    self.num_accumulted_frames = 0;
}
