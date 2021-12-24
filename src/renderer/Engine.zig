const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const Window = @import("../utils/Window.zig");
const Pipeline = @import("./Pipeline.zig");
const SceneDescriptorLayout = @import("./descriptor.zig").SceneDescriptorLayout(3);
const Display = @import("./display.zig").Display(frames_in_flight);
const Camera = @import("./Camera.zig");
const utils = @import("./utils.zig");

const F32x3 = @import("../utils/zug.zig").Vec3(f32);
const Mat4 = @import("../utils/zug.zig").Mat4(f32);

const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const Scene = @import("./Scene.zig");

const frames_in_flight = 2;

const Self = @This();

context: VulkanContext,
display: Display,
commands: Commands,
scene_descriptor_layout: SceneDescriptorLayout,
camera_create_info: Camera.CreateInfo,
camera: Camera,
pipeline: Pipeline,
num_accumulted_frames: u32,
allocator: VkAllocator,

pub fn create(window: *const Window, allocator: std.mem.Allocator) !Self {

    const initial_window_size = window.getExtent();

    const context = try VulkanContext.create(allocator, window);
    var vk_allocator = try VkAllocator.create(&context, allocator);

    var commands = try Commands.create(&context);
    const display = try Display.create(&context, &vk_allocator, allocator, &commands, initial_window_size);

    const scene_descriptor_layout = try SceneDescriptorLayout.create(&context, 1);

    comptime var frames: [frames_in_flight]u32 = undefined;
    comptime for (frames) |_, i| {
        frames[i] = i;
    };

    const camera_origin = F32x3.new(0.4, 0.3, -0.4);
    const camera_target = F32x3.new(0.0, 0.0, 0.0);

    const camera_create_info = .{
        .origin = camera_origin,
        .target = camera_target,
        .up = F32x3.new(0.0, 1.0, 0.0),
        .vfov = 50.0,
        .extent = initial_window_size,
        .aperture = 0.007,
        .focus_distance = camera_origin.sub(camera_target).length(),
    };

    var camera = Camera.new(camera_create_info);

    const pipeline = try Pipeline.create(&context, &vk_allocator, allocator, &commands, &.{ scene_descriptor_layout.handle, display.descriptor_layout.handle }, &[_]Pipeline.ShaderInfoCreateInfo {
        .{ .stage = vk.ShaderStageFlags { .raygen_bit_khr = true }, .filepath = "../../zig-cache/shaders/primary/shader.rgen.spv" },
        .{ .stage = vk.ShaderStageFlags { .miss_bit_khr = true }, .filepath = "../../zig-cache/shaders/primary/shader.rmiss.spv" },
        .{ .stage = vk.ShaderStageFlags { .miss_bit_khr = true }, .filepath = "../../zig-cache/shaders/primary/shadow.rmiss.spv" },
        .{ .stage = vk.ShaderStageFlags { .closest_hit_bit_khr = true }, .filepath = "../../zig-cache/shaders/primary/shader.rchit.spv" },
    }, &[_]vk.PushConstantRange {
        .{
            .offset = 0,
            .size = @sizeOf(Camera.Desc) + @sizeOf(Camera.BlurDesc) + @sizeOf(u32),
            .stage_flags = .{ .raygen_bit_khr = true },
        }
    });

    return Self {
        .context = context,
        .display = display,
        .commands = commands,
        .scene_descriptor_layout = scene_descriptor_layout,
        .camera_create_info = camera_create_info,
        .camera = camera,
        .pipeline = pipeline,
        .num_accumulted_frames = 0,

        .allocator = vk_allocator,
    };
}

pub fn setScene(self: *Self, scene: *const Scene, buffer: vk.CommandBuffer) void {
    self.context.device.cmdBindDescriptorSets(buffer, .ray_tracing_khr, self.pipeline.layout, 0, 1, utils.toPointerType(&scene.descriptor_set), 0, undefined);
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.allocator.destroy(&self.context, allocator);
    self.scene_descriptor_layout.destroy(&self.context);
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

    self.camera.push(&self.context, buffer, self.pipeline.layout);
    const num_accumulted_frames_bytes = std.mem.asBytes(&self.num_accumulted_frames);
    self.context.device.cmdPushConstants(buffer, self.pipeline.layout, .{ .raygen_bit_khr = true }, @sizeOf(Camera.Desc) + @sizeOf(Camera.BlurDesc), num_accumulted_frames_bytes.len, num_accumulted_frames_bytes);

    return buffer;
}

pub fn recordFrame(self: *Self, buffer: vk.CommandBuffer) !void {
    // bind our stuff
    self.context.device.cmdBindPipeline(buffer, .ray_tracing_khr, self.pipeline.handle);
    self.context.device.cmdBindDescriptorSets(buffer, .ray_tracing_khr, self.pipeline.layout, 1, 1, utils.toPointerType(&self.display.frames[self.display.frame_index].set), 0, undefined);
    
    // trace rays
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
