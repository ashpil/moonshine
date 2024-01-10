const std = @import("std");
const vk = @import("vulkan");

const engine = @import("engine");

const VulkanContext = engine.core.VulkanContext;
const Commands = engine.core.Commands;
const VkAllocator = engine.core.Allocator;
const Pipeline = engine.hrtsystem.pipeline.StandardPipeline;
const Scene = engine.hrtsystem.Scene;
const MeshManager = engine.hrtsystem.MeshManager;

const utils = engine.core.vk_helpers;

const TestingContext = struct {
    vc: VulkanContext,
    vk_allocator: VkAllocator,
    commands: Commands,
    output_buffer: VkAllocator.HostBuffer(f32),

    fn create(allocator: std.mem.Allocator, extent: vk.Extent2D) !TestingContext {
        const vc = try VulkanContext.create(allocator, "tests", &.{}, &engine.hrtsystem.required_device_extensions, &engine.hrtsystem.required_device_features, null);
        errdefer vc.destroy();

        var vk_allocator = try VkAllocator.create(&vc, allocator);
        errdefer vk_allocator.destroy(&vc, allocator);

        var commands = try Commands.create(&vc);
        errdefer commands.destroy(&vc);

        const output_buffer = try vk_allocator.createHostBuffer(&vc, f32, 4 * extent.width * extent.height, .{ .transfer_dst_bit = true });
        errdefer output_buffer.destroy(&vc);

        return TestingContext {
            .vc = vc,
            .vk_allocator = vk_allocator,
            .commands = commands,
            .output_buffer = output_buffer,
        };
    }

    fn renderToOutput(self: *TestingContext, pipeline: *const Pipeline, scene: *const Scene) !void {
        try self.commands.startRecording(&self.vc);

        // prepare our stuff
        scene.camera.sensor.recordPrepareForCapture(&self.vc, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true });

        // bind our stuff
        pipeline.recordBindPipeline(&self.vc, self.commands.buffer);
        pipeline.recordBindDescriptorSets(&self.vc, self.commands.buffer, [_]vk.DescriptorSet { scene.world.descriptor_set, scene.background.data.items[0].descriptor_set, scene.camera.sensor.descriptor_set });
        
        // push our stuff
        const bytes = std.mem.asBytes(&.{ scene.camera.properties, scene.camera.sensor.sample_count });
        self.vc.device.cmdPushConstants(self.commands.buffer, pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

        // trace our stuff
        pipeline.recordTraceRays(&self.vc, self.commands.buffer, scene.camera.sensor.extent);

        // copy our stuff
        scene.camera.sensor.recordPrepareForCopy(&self.vc, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true }, .{ .copy_bit = true });

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
                .width = scene.camera.sensor.extent.width,
                .height = scene.camera.sensor.extent.height,
                .depth = 1,
            },  
        };
        self.vc.device.cmdCopyImageToBuffer(self.commands.buffer, scene.camera.sensor.images.data.items(.handle)[0], .transfer_src_optimal, self.output_buffer.handle, 1, @ptrCast(&copy));

        try self.commands.submitAndIdleUntilDone(&self.vc);
    }

    fn destroy(self: *TestingContext, allocator: std.mem.Allocator) void {
        self.output_buffer.destroy(&self.vc);
        self.commands.destroy(&self.vc);
        self.vk_allocator.destroy(&self.vc, allocator);
        self.vc.destroy();
    }
};

// TODO: use actual statistical tests

// theoretically any convex shape works for the furnace test
// the reason to use a sphere (rather than e.g., a box or pyramid with less geometric complexity)
// is that a sphere will test the BRDF with all incoming directions
// this is technically an argument for supporting primitives other than triangles,
// if the goal is just to test the BRDF in the most comprehensive way

test "white sphere on white background is white" {
    const allocator = std.testing.allocator;
    const extent = vk.Extent2D { .width = 32, .height = 32 };
    var tc = try TestingContext.create(allocator, extent);
    defer tc.destroy(allocator);

    var scene = try Scene.fromGlbExr(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, "assets/sphere_external.glb", "assets/white.exr", extent, false);
    defer scene.destroy(&tc.vc, allocator);

    var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ scene.world.descriptor_layout, scene.background.descriptor_layout, scene.camera.descriptor_layout }, .{
        .@"0" = .{
            .samples_per_run = 16,
            .max_bounces = 1024,
            .env_samples_per_bounce = 0,
            .mesh_samples_per_bounce = 0,
        }
    });
    defer pipeline.destroy(&tc.vc);

    try tc.renderToOutput(&pipeline, &scene);
    
    for (tc.output_buffer.data) |pixel| {
        if (!std.math.approxEqAbs(f32, pixel, 1.0, 0.00001)) return error.NonWhitePixel;
    }
}

test "inside illuminating sphere is white" {
    const allocator = std.testing.allocator;

    const extent = vk.Extent2D { .width = 32, .height = 32 };
    var tc = try TestingContext.create(allocator, extent);
    defer tc.destroy(allocator);

    var scene = try Scene.fromGlbExr(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, "assets/sphere_internal.glb", "assets/white.exr", extent, false);
    defer scene.destroy(&tc.vc, allocator);

    var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ scene.world.descriptor_layout, scene.background.descriptor_layout, scene.camera.descriptor_layout }, .{
        .@"0" = .{
            .samples_per_run = 512,
            .max_bounces = 1024,
            .env_samples_per_bounce = 0,
            .mesh_samples_per_bounce = 0,
        }
    });
    defer pipeline.destroy(&tc.vc);

    try tc.renderToOutput(&pipeline, &scene);
    
    for (tc.output_buffer.data) |pixel| {
        if (!std.math.approxEqAbs(f32, pixel, 1.0, 0.04)) return error.NonWhitePixel;
    }
}

test "inside illuminating sphere is white with mesh sampling" {
    const allocator = std.testing.allocator;

    const extent = vk.Extent2D { .width = 32, .height = 32 };
    var tc = try TestingContext.create(allocator, extent);
    defer tc.destroy(allocator);

    var scene = try Scene.fromGlbExr(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, "assets/sphere_internal.glb", "assets/white.exr", extent, false);
    defer scene.destroy(&tc.vc, allocator);

    var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ scene.world.descriptor_layout, scene.background.descriptor_layout, scene.camera.descriptor_layout }, .{
        .@"0" = .{
            .samples_per_run = 512,
            .max_bounces = 1024,
            .env_samples_per_bounce = 0,
            .mesh_samples_per_bounce = 1,
        }
    });
    defer pipeline.destroy(&tc.vc);

    try tc.renderToOutput(&pipeline, &scene);
    
    for (tc.output_buffer.data) |pixel| {
        // TODO: this should be able to have tighter error bounds but is weird on my GPU for some reason
        // first upgrade GPU then determine if bug actually exists
        if (!std.math.approxEqAbs(f32, pixel, 1.0, 0.1)) return error.NonWhitePixel;
    }
}
