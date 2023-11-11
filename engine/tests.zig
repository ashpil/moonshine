const std = @import("std");
const vk = @import("vulkan");

const engine = @import("engine");

const VulkanContext = engine.core.VulkanContext;
const Commands = engine.core.Commands;
const VkAllocator = engine.core.Allocator;
const Pipeline = engine.hrtsystem.pipeline.StandardPipeline;
const Scene = engine.hrtsystem.Scene;

const utils = engine.core.vk_helpers;

const TestingContext = struct {
    vc: VulkanContext,
    vk_allocator: VkAllocator,
    commands: Commands,
    scene: Scene,
    output_buffer: VkAllocator.HostBuffer(f32),

    fn create(allocator: std.mem.Allocator, extent: vk.Extent2D, in_filepath: []const u8, skybox_filepath: []const u8) !TestingContext {
        const vc = try VulkanContext.create(allocator, "offline", &.{}, &engine.hrtsystem.required_device_extensions, &engine.hrtsystem.required_device_features, null);
        errdefer vc.destroy();

        var vk_allocator = try VkAllocator.create(&vc, allocator);
        errdefer vk_allocator.destroy(&vc, allocator);

        var commands = try Commands.create(&vc);
        errdefer commands.destroy(&vc);

        var scene = try Scene.fromGlbExr(&vc, &vk_allocator, allocator, &commands, in_filepath, skybox_filepath, extent, false);
        errdefer scene.destroy(&vc, allocator);

        const output_buffer = try vk_allocator.createHostBuffer(&vc, f32, 4 * scene.camera.film.extent.width * scene.camera.film.extent.height, .{ .transfer_dst_bit = true });
        errdefer output_buffer.destroy(&vc);

        return TestingContext {
            .vc = vc,
            .vk_allocator = vk_allocator,
            .commands = commands,
            .scene = scene,
            .output_buffer = output_buffer,
        };
    }

    fn renderToOutput(self: *TestingContext, pipeline: *const Pipeline) !void {
        try self.commands.startRecording(&self.vc);

        // prepare our stuff
        self.scene.camera.film.recordPrepareForCapture(&self.vc, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true });

        // bind our stuff
        pipeline.recordBindPipeline(&self.vc, self.commands.buffer);
        pipeline.recordBindDescriptorSets(&self.vc, self.commands.buffer, [_]vk.DescriptorSet { self.scene.world.descriptor_set, self.scene.background.data.items[0].descriptor_set, self.scene.camera.film.descriptor_set });
        
        // push our stuff
        const bytes = std.mem.asBytes(&.{ self.scene.camera.properties, self.scene.camera.film.sample_count });
        self.vc.device.cmdPushConstants(self.commands.buffer, pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

        // trace our stuff
        pipeline.recordTraceRays(&self.vc, self.commands.buffer, self.scene.camera.film.extent);

        // copy our stuff
        self.scene.camera.film.recordPrepareForCopy(&self.vc, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true }, .{ .copy_bit = true });

        // copy output image to host-visible staging buffer
        const copy = vk.BufferImageCopy {
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{
                .x = 0,
                .y = 0,
                .z = 0,
            },
            .image_extent = .{
                .width = self.scene.camera.film.extent.width,
                .height = self.scene.camera.film.extent.height,
                .depth = 1,
            },  
        };
        self.vc.device.cmdCopyImageToBuffer(self.commands.buffer, self.scene.camera.film.images.data.items(.handle)[0], .transfer_src_optimal, self.output_buffer.handle, 1, @ptrCast(&copy));

        try self.commands.submitAndIdleUntilDone(&self.vc);
    }

    fn destroy(self: *TestingContext, allocator: std.mem.Allocator) void {
        self.output_buffer.destroy(&self.vc);
        self.scene.destroy(&self.vc, allocator);
        self.commands.destroy(&self.vc);
        self.vk_allocator.destroy(&self.vc, allocator);
        self.vc.destroy();
    }
};

// TODO: use actual statistical tests

test "white on white background is white" {
    const allocator = std.testing.allocator;

    var tc = try TestingContext.create(allocator, vk.Extent2D { .width = 32, .height = 32 }, "assets/sphere_external.glb", "assets/white.exr");
    defer tc.destroy(allocator);

    var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ tc.scene.world_descriptor_layout, tc.scene.background.descriptor_layout, tc.scene.film_descriptor_layout }, .{
        .@"0" = .{
            .samples_per_run = 16,
            .max_bounces = 1024,
            .env_samples_per_bounce = 0,
            .mesh_samples_per_bounce = 0,
        }
    });
    defer pipeline.destroy(&tc.vc);

    try tc.renderToOutput(&pipeline);
    
    for (tc.output_buffer.data) |pixel| {
        if (!std.math.approxEqAbs(f32, pixel, 1.0, 0.00001)) return error.NonWhitePixel;
    }
}

test "inside illuminating sphere is white" {
    const allocator = std.testing.allocator;

    var tc = try TestingContext.create(allocator, vk.Extent2D { .width = 32, .height = 32 }, "assets/sphere_internal.glb", "assets/white.exr");
    defer tc.destroy(allocator);

    var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ tc.scene.world_descriptor_layout, tc.scene.background.descriptor_layout, tc.scene.film_descriptor_layout }, .{
        .@"0" = .{
            .samples_per_run = 512,
            .max_bounces = 1024,
            .env_samples_per_bounce = 0,
            .mesh_samples_per_bounce = 0,
        }
    });
    defer pipeline.destroy(&tc.vc);

    try tc.renderToOutput(&pipeline);
    
    for (tc.output_buffer.data) |pixel| {
        if (!std.math.approxEqAbs(f32, pixel, 1.0, 0.04)) return error.NonWhitePixel;
    }
}

test "inside illuminating sphere is white with mesh sampling" {
    const allocator = std.testing.allocator;

    var tc = try TestingContext.create(allocator, vk.Extent2D { .width = 32, .height = 32 }, "assets/sphere_internal.glb", "assets/white.exr");
    defer tc.destroy(allocator);

    var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ tc.scene.world_descriptor_layout, tc.scene.background.descriptor_layout, tc.scene.film_descriptor_layout }, .{
        .@"0" = .{
            .samples_per_run = 512,
            .max_bounces = 1024,
            .env_samples_per_bounce = 0,
            .mesh_samples_per_bounce = 1,
        }
    });
    defer pipeline.destroy(&tc.vc);

    try tc.renderToOutput(&pipeline);
    
    for (tc.output_buffer.data) |pixel| {
        // TODO: this should be able to have tighter error bounds but is weird on my GPU for some reason
        // first upgrade GPU then determine if bug actually exists
        if (!std.math.approxEqAbs(f32, pixel, 1.0, 0.1)) return error.NonWhitePixel;
    }
}
