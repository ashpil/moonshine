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
    try writer.print("{}.{}", .{ s, ms });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // parse cli args
    const params = blk: {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);
        if (args.len < 3) return error.BadArgs;

        const in_filename = args[1];
        if (!std.mem.eql(u8, std.fs.path.extension(in_filename), ".glb")) return error.OnlySupportsGlbInput;

        const out_filename = args[2];
        if (!std.mem.eql(u8, std.fs.path.extension(out_filename), ".exr")) return error.OnlySupportsExrOutput;

        const spp = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 16;

        break :blk .{
            .in_filename = try allocator.dupe(u8, in_filename),
            .out_filename = try allocator.dupeZ(u8, out_filename), // ugh
            .spp = spp,
        };
    };
    defer {
        allocator.free(params.in_filename);
        allocator.free(params.out_filename);
    }

    var context = try VulkanContext.create(.{ .allocator = allocator, .app_name = "offline" });
    defer context.destroy();

    var vk_allocator = try VkAllocator.create(&context, allocator);
    defer vk_allocator.destroy(&context, allocator);

    var scene_descriptor_layout = try SceneDescriptorLayout.create(&context, 1, .{
        .{},
        .{},
        .{},
        .{ .partially_bound_bit = true },
        .{},
        .{},
        .{},
    });
    defer scene_descriptor_layout.destroy(&context);
    var background_descriptor_layout = try BackgroundDescriptorLayout.create(&context, 1, null);
    defer background_descriptor_layout.destroy(&context);
    var output_descriptor_layout = try OutputDescriptorLayout.create(&context, 1, null);
    defer output_descriptor_layout.destroy(&context);

    var commands = try Commands.create(&context);
    defer commands.destroy(&context);

    var pipeline = try Pipeline.createStandardPipeline(&context, &vk_allocator, allocator, &commands, &scene_descriptor_layout, &background_descriptor_layout, &output_descriptor_layout, .{
        .samples_per_run = params.spp,
        .max_bounces = 4,
        .direct_samples_per_bounce = 2,
    });
    defer pipeline.destroy(&context);

    const extent = vk.Extent2D { .width = 1024, .height = 1024 }; // TODO: cli

    const camera_origin = F32x3.new(1.0, 1.5, 3.0);
    const camera_target = F32x3.new(0.0, 0.2, 0.0);
    const camera_create_info = .{
        .origin = camera_origin,
        .target = camera_target,
        .up = F32x3.new(0.0, 1.0, 0.0),
        .vfov = 65.0,
        .extent = extent,
        .aperture = 0.007,
        .focus_distance = camera_origin.sub(camera_target).length(),
    };
    const camera = Camera.new(camera_create_info);

    const display_image_info = ImageManager.ImageCreateRawInfo {
        .extent = extent,
        .usage = .{ .storage_bit = true, .transfer_src_bit = true, },
        .format = .r32g32b32a32_sfloat,
    };
    var display_image = try ImageManager.createRaw(&context, &vk_allocator, allocator, &.{ display_image_info });
    defer display_image.destroy(&context, allocator);

    const accumulation_image_info = [_]ImageManager.ImageCreateRawInfo {
        .{
            .extent = extent,
            .usage = .{ .storage_bit = true, },
            .format = .r32g32b32a32_sfloat,
        },
    };
    var accumulation_image = try ImageManager.createRaw(&context, &vk_allocator, allocator, &accumulation_image_info);
    defer accumulation_image.destroy(&context, allocator);

    const output_sets = try output_descriptor_layout.allocate_sets(&context, 1, [_]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = .null_handle,
                .image_view = display_image.data.items(.view)[0],
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
                .image_view = accumulation_image.data.items(.view)[0],
                .image_layout = .general,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    });

    const start_time = try std.time.Instant.now();
    var scene = try Scene.fromGlb(&context, &vk_allocator, allocator, &commands, params.in_filename, "./assets/textures/skybox/", &scene_descriptor_layout, &background_descriptor_layout);
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

    const display_image_bytes = try vk_allocator.createHostBuffer(&context, u8, @intCast(u32, display_image.data.items(.size_in_bytes)[0]), .{ .transfer_dst_bit = true });
    defer display_image_bytes.destroy(&context);
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
                .image = accumulation_image.data.items(.handle)[0],
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
                .image = display_image.data.items(.handle)[0],
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
            .image = display_image.data.items(.handle)[0],
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
        context.device.cmdCopyImageToBuffer(command_buffer, display_image.data.items(.handle)[0], .transfer_src_optimal, display_image_bytes.handle, 1, utils.toPointerType(&copy));

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
    var f32_slice: []const f32 = undefined;
    f32_slice.ptr = @ptrCast([*]f32, @alignCast(@alignOf(f32), display_image_bytes.data.ptr));
    f32_slice.len = display_image_bytes.data.len / 4;
    try exr.helpers.save(allocator, f32_slice, 4, extent, params.out_filename);

    const exr_time = try std.time.Instant.now();
    try printTime(stdout, exr_time.since(render_time));
    try stdout.print(" seconds to write exr\n", .{});
}
