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

const Config = struct {
    in_filepath: []const u8, // must be glb
    out_filepath: [:0]const u8, // must be exr
    skybox_filepath: []const u8, // must be exr
    spp: u32,
    extent: vk.Extent2D,

    fn fromCli(allocator: std.mem.Allocator) !Config {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);
        if (args.len < 4) return error.BadArgs;

        const in_filepath = args[1];
        if (!std.mem.eql(u8, std.fs.path.extension(in_filepath), ".glb")) return error.OnlySupportsGlbInput;

        const skybox_filepath = args[2];
        if (!std.mem.eql(u8, std.fs.path.extension(skybox_filepath), ".exr")) return error.OnlySupportsExrSkybox;

        const out_filepath = args[3];
        if (!std.mem.eql(u8, std.fs.path.extension(out_filepath), ".exr")) return error.OnlySupportsExrOutput;

        const spp = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else 16;

        return Config {
            .in_filepath = try allocator.dupe(u8, in_filepath),
            .out_filepath = try allocator.dupeZ(u8, out_filepath), // ugh
            .skybox_filepath = try allocator.dupe(u8, skybox_filepath),
            .spp = spp,
            .extent = vk.Extent2D { .width = 1280, .height = 720 }, // TODO: cli
        };
    }

    fn destroy(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.in_filepath);
        allocator.free(self.out_filepath);
        allocator.free(self.skybox_filepath);
    }
};

const IntervalLogger = struct {
    last_time: std.time.Instant,

    fn start() !IntervalLogger {
        return IntervalLogger {
            .last_time = try std.time.Instant.now(),
        };
    }

    fn log(self: *IntervalLogger, state: []const u8) !void {
        const new_time = try std.time.Instant.now();
        const elapsed = new_time.since(self.last_time);
        const ms = elapsed / std.time.ns_per_ms;
        const s = ms / std.time.ms_per_s;
        try std.io.getStdOut().writer().print("{}.{:0>3} seconds to {s}\n", .{ s, ms, state });
        self.last_time = new_time;
    }
};

pub fn main() !void {
    var logger = try IntervalLogger.start();

    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try Config.fromCli(allocator);
    defer config.destroy(allocator);

    const context = try VulkanContext.create(.{ .allocator = allocator, .app_name = "offline" });
    defer context.destroy();

    var vk_allocator = try VkAllocator.create(&context, allocator);
    defer vk_allocator.destroy(&context, allocator);

    var world_descriptor_layout = try WorldDescriptorLayout.create(&context, 1, .{});
    defer world_descriptor_layout.destroy(&context);
    var background_descriptor_layout = try BackgroundDescriptorLayout.create(&context, 1, .{});
    defer background_descriptor_layout.destroy(&context);
    var film_descriptor_layout = try FilmDescriptorLayout.create(&context, 1, .{});
    defer film_descriptor_layout.destroy(&context);

    var commands = try Commands.create(&context);
    defer commands.destroy(&context);

    var pipeline = try Pipeline.create(&context, &vk_allocator, allocator, &commands, .{ world_descriptor_layout, background_descriptor_layout, film_descriptor_layout }, .{ .{
        .samples_per_run = 1,
        .max_bounces = 1024,
        .env_samples_per_bounce = 1,
        .mesh_samples_per_bounce = 1,
    }});
    defer pipeline.destroy(&context);

    try logger.log("set up initial state");

    var camera = try Camera.fromGlb(&context, &vk_allocator, allocator, &film_descriptor_layout, config.extent, config.in_filepath);
    defer camera.destroy(&context, allocator);

    var world = try World.fromGlb(&context, &vk_allocator, allocator, &commands, &world_descriptor_layout, config.in_filepath);
    defer world.destroy(&context, allocator);

    try logger.log("load world");

    var background = try Background.create(&context, &vk_allocator, allocator, &commands, &background_descriptor_layout, world.sampler, config.skybox_filepath);
    defer background.destroy(&context, allocator);

    try logger.log("load background");
    
    const output_buffer = try vk_allocator.createHostBuffer(&context, f32, 4 * camera.film.extent.width * camera.film.extent.height, .{ .transfer_dst_bit = true });
    defer output_buffer.destroy(&context);
    // record command buffer
    {
        try commands.startRecording(&context);

        // transition images to general layout
        const barriers = [_]vk.ImageMemoryBarrier2 {
            .{
                .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .@"undefined",
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = camera.film.images.data.items(.handle)[0],
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
                .image = camera.film.images.data.items(.handle)[1],
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            },
        };

        context.device.cmdPipelineBarrier2(commands.buffer, &vk.DependencyInfo {
            .image_memory_barrier_count = @intCast(u32, barriers.len),
            .p_image_memory_barriers = &barriers,
        });

        // bind our stuff
        pipeline.recordBindPipeline(&context, commands.buffer);
        pipeline.recordBindDescriptorSets(&context, commands.buffer, [_]vk.DescriptorSet { world.descriptor_set, background.descriptor_set, camera.film.descriptor_set });
        
        var i: u32 = 0;
        while (i < config.spp) : (i += 1) {
            // push our stuff
            const bytes = std.mem.asBytes(&.{ camera.properties, i });
            context.device.cmdPushConstants(commands.buffer, pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

            // trace our stuff
            pipeline.recordTraceRays(&context, commands.buffer, camera.film.extent);

            // if not last invocation, need barrier cuz we write to images
            if (i != config.spp) {
                const rt_barriers = [_]vk.ImageMemoryBarrier2 {
                    .{
                        .src_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                        .src_access_mask = .{ .shader_write_bit = true },
                        .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                        .dst_access_mask = .{ .shader_write_bit = true },
                        .old_layout = .general,
                        .new_layout = .general,
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .image = camera.film.images.data.items(.handle)[0],
                        .subresource_range = .{
                            .aspect_mask = .{ .color_bit = true },
                            .base_mip_level = 0,
                            .level_count = 1,
                            .base_array_layer = 0,
                            .layer_count = vk.REMAINING_ARRAY_LAYERS,
                        },
                    },
                    .{
                        .src_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                        .src_access_mask = .{ .shader_write_bit = true },
                        .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                        .dst_access_mask = .{ .shader_write_bit = true },
                        .old_layout = .general,
                        .new_layout = .general,
                        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                        .image = camera.film.images.data.items(.handle)[1],
                        .subresource_range = .{
                            .aspect_mask = .{ .color_bit = true },
                            .base_mip_level = 0,
                            .level_count = 1,
                            .base_array_layer = 0,
                            .layer_count = vk.REMAINING_ARRAY_LAYERS,
                        },
                    },
                };

                context.device.cmdPipelineBarrier2(commands.buffer, &vk.DependencyInfo {
                    .image_memory_barrier_count = @intCast(u32, rt_barriers.len),
                    .p_image_memory_barriers = &rt_barriers,
                });
            }
        }

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
            .image = camera.film.images.data.items(.handle)[0],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
        };
        context.device.cmdPipelineBarrier2(commands.buffer, &vk.DependencyInfo {
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
                .width = camera.film.extent.width,
                .height = camera.film.extent.height,
                .depth = 1,
            },  
        };
        context.device.cmdCopyImageToBuffer(commands.buffer, camera.film.images.data.items(.handle)[0], .transfer_src_optimal, output_buffer.handle, 1, utils.toPointerType(&copy));

        try commands.submitAndIdleUntilDone(&context);
    }

    try logger.log("render");

    // now done with GPU stuff/all rendering; can write from output buffer to exr
    try exr.helpers.save(allocator, output_buffer.data, 4, camera.film.extent, config.out_filepath);

    try logger.log("write exr");
}
