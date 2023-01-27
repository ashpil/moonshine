const std = @import("std");
const vk = @import("vulkan");

const engine = @import("engine");

const VulkanContext = engine.rendersystem.VulkanContext;
const Commands = engine.rendersystem.Commands;
const VkAllocator = engine.rendersystem.Allocator;
const Pipeline = engine.rendersystem.Pipeline;
const ImageManager = engine.rendersystem.ImageManager;
const Camera = engine.rendersystem.Camera;
const Scene = engine.rendersystem.Scene;
const Material = engine.rendersystem.Scene.Material;

const utils = engine.rendersystem.utils;
const exr = engine.fileformats.exr;

const descriptor = engine.rendersystem.descriptor;
const SceneDescriptorLayout = descriptor.SceneDescriptorLayout;
const BackgroundDescriptorLayout = descriptor.BackgroundDescriptorLayout;
const OutputDescriptorLayout = descriptor.OutputDescriptorLayout;

const vector = engine.vector;
const F32x3 = vector.Vec3(f32);
const Mat3x4 = vector.Mat3x4(f32);

fn printTime(writer: anytype, time: u64) !void {
    const ms = time / std.time.ns_per_ms;
    const s = ms / std.time.ms_per_s;
    try writer.print("{}.{:0>3}", .{ s, ms });
}

const Config = struct {
    in_filepath: []const u8, // must be glb
    out_filepath: [:0]const u8, // must be exr
    skybox_filepath: []const u8, // must be exr
    spp: u32,

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
        };
    }

    fn destroy(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.in_filepath);
        allocator.free(self.out_filepath);
        allocator.free(self.skybox_filepath);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var params = try Config.fromCli(allocator);
    defer params.destroy(allocator);

    var context = try VulkanContext.create(.{ .allocator = allocator, .app_name = "offline" });
    defer context.destroy();

    var vk_allocator = try VkAllocator.create(&context, allocator);
    defer vk_allocator.destroy(&context, allocator);

    var scene_descriptor_layout = try SceneDescriptorLayout.create(&context, 1);
    defer scene_descriptor_layout.destroy(&context);
    var background_descriptor_layout = try BackgroundDescriptorLayout.create(&context, 1);
    defer background_descriptor_layout.destroy(&context);
    var output_descriptor_layout = try OutputDescriptorLayout.create(&context, 1);
    defer output_descriptor_layout.destroy(&context);

    var commands = try Commands.create(&context);
    defer commands.destroy(&context);

    var pipeline = try Pipeline.createStandardPipeline(&context, &vk_allocator, allocator, &commands, &scene_descriptor_layout, &background_descriptor_layout, &output_descriptor_layout, .{
        .samples_per_run = params.spp,
        .max_bounces = 1024,
        .env_samples_per_bounce = 1,
        .mesh_samples_per_bounce = 1,
    });
    defer pipeline.destroy(&context);

    const extent = vk.Extent2D { .width = 1280, .height = 720 }; // TODO: cli
    const camera = try Camera.fromGlb(allocator, params.in_filepath, extent);

    var output_images = try ImageManager.createRaw(&context, &vk_allocator, allocator, &.{
        .{ // display
            .extent = extent,
            .usage = .{ .storage_bit = true, .transfer_src_bit = true, },
            .format = .r32g32b32a32_sfloat,
        },
        .{ // accumulation
            .extent = extent,
            .usage = .{ .storage_bit = true, },
            .format = .r32g32b32a32_sfloat,
        },
    });
    defer output_images.destroy(&context, allocator);

    const output_images_slice = output_images.data.slice();
    const output_image_views = output_images_slice.items(.view);
    const output_image_handles = output_images_slice.items(.handle);
    const output_image_size_in_bytes = output_images_slice.items(.size_in_bytes)[0];

    const output_sets = try output_descriptor_layout.allocate_sets(&context, 1, [_]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = .null_handle,
                .image_view = output_image_views[0],
                .image_layout = .general,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = .null_handle,
                .image_view = output_image_views[1],
                .image_layout = .general,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    });

    const start_time = try std.time.Instant.now();
    var scene = try Scene.fromGlb(&context, &vk_allocator, allocator, &commands, params.in_filepath, params.skybox_filepath, &scene_descriptor_layout, &background_descriptor_layout);
    defer scene.destroy(&context, allocator);
    const scene_time = try std.time.Instant.now();
    const stdout = std.io.getStdOut().writer();
    try printTime(stdout, scene_time.since(start_time));
    try stdout.print(" seconds to load scene\n", .{});
    
    const command_pool = try context.device.createCommandPool(&.{
        .queue_family_index = context.physical_device.queue_family_index,
        .flags = .{ .transient_bit = true },
    }, null);
    defer context.device.destroyCommandPool(command_pool, null);

    var command_buffer: vk.CommandBuffer = undefined;
    try context.device.allocateCommandBuffers(&.{
        .level = vk.CommandBufferLevel.primary,
        .command_pool = command_pool,
        .command_buffer_count = 1,
    }, @ptrCast([*]vk.CommandBuffer, &command_buffer));

    const output_buffer = try vk_allocator.createHostBuffer(&context, f32, @intCast(u32, output_image_size_in_bytes) / 4, .{ .transfer_dst_bit = true });
    defer output_buffer.destroy(&context);
    // record command buffer
    {
        try context.device.beginCommandBuffer(command_buffer, &.{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });

        // transition images to general layout
        const barriers = [_]vk.ImageMemoryBarrier2 {
            .{
                .src_stage_mask = .{},
                .src_access_mask = .{},
                .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .@"undefined",
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = output_image_handles[0],
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            },
            .{
                .src_stage_mask = .{},
                .src_access_mask = .{},
                .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .@"undefined",
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = output_image_handles[1],
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            },
        };

        context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = undefined,
            .buffer_memory_barrier_count = 0,
            .p_buffer_memory_barriers = undefined,
            .image_memory_barrier_count = @intCast(u32, barriers.len),
            .p_image_memory_barriers = &barriers,
        });

        // bind our stuff
        context.device.cmdBindPipeline(command_buffer, .ray_tracing_khr, pipeline.handle);
        context.device.cmdBindDescriptorSets(command_buffer, .ray_tracing_khr, pipeline.layout, 0, 3, &[_]vk.DescriptorSet { scene.descriptor_set, scene.background.descriptor_set, output_sets[0] }, 0, undefined);
        
        // push our stuff
        const bytes = std.mem.asBytes(&.{camera.desc, camera.blur_desc, 0});
        context.device.cmdPushConstants(command_buffer, pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

        // trace our stuff
        pipeline.traceRays(&context, command_buffer, extent);

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
            .image = output_image_handles[0],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
        };
        context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
            .dependency_flags = .{},
            .memory_barrier_count = 0,
            .p_memory_barriers = undefined,
            .buffer_memory_barrier_count = 0,
            .p_buffer_memory_barriers = undefined,
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
                .width = extent.width,
                .height = extent.height,
                .depth = 1,
            },  
        };
        context.device.cmdCopyImageToBuffer(command_buffer, output_image_handles[0], .transfer_src_optimal, output_buffer.handle, 1, utils.toPointerType(&copy));

        try context.device.endCommandBuffer(command_buffer);
    }

    try context.device.queueSubmit2(context.queue, 1, &[_]vk.SubmitInfo2 { .{
        .flags = .{},
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = utils.toPointerType(&vk.CommandBufferSubmitInfo {
            .command_buffer = command_buffer,
            .device_mask = 0,
        }),
        .wait_semaphore_info_count = 0,
        .p_wait_semaphore_infos = undefined,
        .signal_semaphore_info_count = 0,
        .p_signal_semaphore_infos = undefined,
    }}, vk.Fence.null_handle);

    try context.device.deviceWaitIdle();

    const render_time = try std.time.Instant.now();
    try printTime(stdout, render_time.since(scene_time));
    try stdout.print(" seconds to render\n", .{});

    // now done with GPU stuff/all rendering; can write from output buffer to exr
    try exr.helpers.save(allocator, output_buffer.data, 4, extent, params.out_filepath);

    const exr_time = try std.time.Instant.now();
    try printTime(stdout, exr_time.since(render_time));
    try stdout.print(" seconds to write exr\n", .{});
}
