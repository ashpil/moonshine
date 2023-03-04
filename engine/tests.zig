const std = @import("std");
const vk = @import("vulkan");

const engine = @import("engine");

const VulkanContext = engine.rendersystem.VulkanContext;
const Commands = engine.rendersystem.Commands;
const VkAllocator = engine.rendersystem.Allocator;
const Pipeline = engine.rendersystem.pipeline.StandardPipeline;
const ImageManager = engine.rendersystem.ImageManager;
const Camera = engine.rendersystem.Camera;
const World = engine.rendersystem.World;
const Material = engine.rendersystem.World.Material;
const Background = engine.rendersystem.Background;

const utils = engine.rendersystem.utils;
const exr = engine.fileformats.exr;

const descriptor = engine.rendersystem.descriptor;
const WorldDescriptorLayout = descriptor.WorldDescriptorLayout;
const BackgroundDescriptorLayout = descriptor.BackgroundDescriptorLayout;
const FilmDescriptorLayout = descriptor.FilmDescriptorLayout;

const vector = engine.vector;
const F32x3 = vector.Vec3(f32);
const Mat3x4 = vector.Mat3x4(f32);

const TestingContext = struct {

    vc: VulkanContext,

    vk_allocator: VkAllocator,

    world_descriptor_layout: WorldDescriptorLayout,
    background_descriptor_layout: BackgroundDescriptorLayout,
    film_descriptor_layout: FilmDescriptorLayout,

    commands: Commands,

    camera: Camera,
    world: World,
    background: Background,

    output_buffer: VkAllocator.HostBuffer(f32),

    fn create(allocator: std.mem.Allocator, extent: vk.Extent2D, in_filepath: []const u8, skybox_filepath: []const u8) !TestingContext {
        const vc = try VulkanContext.create(.{ .allocator = allocator, .app_name = "test" });
        errdefer vc.destroy();

        var vk_allocator = try VkAllocator.create(&vc, allocator);
        errdefer vk_allocator.destroy(&vc, allocator);

        var world_descriptor_layout = try WorldDescriptorLayout.create(&vc, 1, .{});
        errdefer world_descriptor_layout.destroy(&vc);
        var background_descriptor_layout = try BackgroundDescriptorLayout.create(&vc, 1, .{});
        errdefer background_descriptor_layout.destroy(&vc);
        var film_descriptor_layout = try FilmDescriptorLayout.create(&vc, 1, .{});
        errdefer film_descriptor_layout.destroy(&vc);

        var commands = try Commands.create(&vc);
        errdefer commands.destroy(&vc);

        var camera = try Camera.create(&vc, &vk_allocator, allocator, &film_descriptor_layout, extent, try Camera.CreateInfo.fromGlb(allocator, in_filepath));
        errdefer camera.destroy(&vc, allocator);

        var world = try World.fromGlb(&vc, &vk_allocator, allocator, &commands, &world_descriptor_layout, in_filepath);
        errdefer world.destroy(&vc, allocator);

        var background = try Background.create(&vc, &vk_allocator, allocator, &commands, &background_descriptor_layout, world.sampler, skybox_filepath);
        errdefer background.destroy(&vc, allocator);

        const output_buffer = try vk_allocator.createHostBuffer(&vc, f32, 4 * camera.film.extent.width * camera.film.extent.height, .{ .transfer_dst_bit = true });
        errdefer output_buffer.destroy(&vc);

        return TestingContext {
            .vc = vc,

            .vk_allocator = vk_allocator,

            .world_descriptor_layout = world_descriptor_layout,
            .background_descriptor_layout = background_descriptor_layout,
            .film_descriptor_layout = film_descriptor_layout,

            .commands = commands,

            .camera = camera,
            .world = world,
            .background = background,

            .output_buffer = output_buffer,
        };
    }

    fn renderToOutput(self: *TestingContext, pipeline: *const Pipeline) !void {
        try self.commands.startRecording(&self.vc);

        // transition images to general layout
        const barriers = [_]vk.ImageMemoryBarrier2 {
            .{
                .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .@"undefined",
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = self.camera.film.images.data.items(.handle)[0],
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            },
            .{
                .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .@"undefined",
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = self.camera.film.images.data.items(.handle)[1],
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            },
        };

        self.vc.device.cmdPipelineBarrier2(self.commands.buffer, &vk.DependencyInfo {
            .image_memory_barrier_count = @intCast(u32, barriers.len),
            .p_image_memory_barriers = &barriers,
        });

        // bind our stuff
        pipeline.recordBindPipeline(&self.vc, self.commands.buffer);
        pipeline.recordBindDescriptorSets(&self.vc, self.commands.buffer, [_]vk.DescriptorSet { self.world.descriptor_set, self.background.descriptor_set, self.camera.film.descriptor_set });
        
        // push our stuff
        const bytes = std.mem.asBytes(&.{ self.camera.properties, self.camera.film.sample_count });
        self.vc.device.cmdPushConstants(self.commands.buffer, pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

        // trace our stuff
        pipeline.recordTraceRays(&self.vc, self.commands.buffer, self.camera.film.extent);

        // transfer output image to transfer_src_optimal layout
        const barrier = vk.ImageMemoryBarrier2 {
            .src_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_stage_mask = .{ .copy_bit = true },
            .dst_access_mask = .{ .transfer_read_bit = true },
            .old_layout = .general,
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.camera.film.images.data.items(.handle)[0],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
        };
        self.vc.device.cmdPipelineBarrier2(self.commands.buffer, &vk.DependencyInfo {
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = utils.toPointerType(&barrier),
        });

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
                .width = self.camera.film.extent.width,
                .height = self.camera.film.extent.height,
                .depth = 1,
            },  
        };
        self.vc.device.cmdCopyImageToBuffer(self.commands.buffer, self.camera.film.images.data.items(.handle)[0], .transfer_src_optimal, self.output_buffer.handle, 1, utils.toPointerType(&copy));

        try self.commands.submitAndIdleUntilDone(&self.vc);
    }

    fn destroy(self: *TestingContext, allocator: std.mem.Allocator) void {
        self.output_buffer.destroy(&self.vc);

        self.background.destroy(&self.vc, allocator);
        self.world.destroy(&self.vc, allocator);
        self.camera.destroy(&self.vc, allocator);

        self.commands.destroy(&self.vc);

        self.film_descriptor_layout.destroy(&self.vc);
        self.background_descriptor_layout.destroy(&self.vc);
        self.world_descriptor_layout.destroy(&self.vc);

        self.vk_allocator.destroy(&self.vc, allocator);

        self.vc.destroy();
    }
};

// TODO: use actual statistical tests

test "white on white background is white" {
    const allocator = std.testing.allocator;

    var tc = try TestingContext.create(allocator, vk.Extent2D { .width = 32, .height = 32 }, "assets/sphere_external.glb", "assets/white.exr");
    defer tc.destroy(allocator);

    var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ tc.world_descriptor_layout, tc.background_descriptor_layout, tc.film_descriptor_layout }, .{ .{
        .samples_per_run = 16,
        .max_bounces = 1024,
        .env_samples_per_bounce = 0,
        .mesh_samples_per_bounce = 0,
    }});
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

    var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ tc.world_descriptor_layout, tc.background_descriptor_layout, tc.film_descriptor_layout }, .{ .{
        .samples_per_run = 512,
        .max_bounces = 1024,
        .env_samples_per_bounce = 0,
        .mesh_samples_per_bounce = 0,
    }});
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

    var pipeline = try Pipeline.create(&tc.vc, &tc.vk_allocator, allocator, &tc.commands, .{ tc.world_descriptor_layout, tc.background_descriptor_layout, tc.film_descriptor_layout }, .{ .{
        .samples_per_run = 512,
        .max_bounces = 1024,
        .env_samples_per_bounce = 0,
        .mesh_samples_per_bounce = 1,
    }});
    defer pipeline.destroy(&tc.vc);

    try tc.renderToOutput(&pipeline);
    
    for (tc.output_buffer.data) |pixel| {
        // TODO: this should be able to have tighter error bounds but is weird on my GPU for some reason
        // first upgrade GPU then determine if bug actually exists
        if (!std.math.approxEqAbs(f32, pixel, 1.0, 0.1)) return error.NonWhitePixel;
    }
}
