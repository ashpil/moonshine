const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const VulkanContext = engine.core.VulkanContext;
const Encoder = engine.core.Encoder;
const Image = engine.core.Image;

const Rgba2D = engine.fileformats.exr.helpers.Rgba2D;

data: std.ArrayListUnmanaged(struct {
    luminance_image: Image,
    rgb_image: Image,
}),
sampler: vk.Sampler,
equirectangular_to_equal_area_pipeline: EquirectangularToEqualAreaPipeline,
luminance_pipeline: LuminancePipeline,
fold_pipeline: FoldPipeline,

const Self = @This();

fn luminance(rgb: [3]f32) f32 {
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}

const EquirectangularToEqualAreaPipeline = engine.core.pipeline.Pipeline(.{ .shader_path = "hrtsystem/background/equirectangular_to_equal_area.hlsl", .PushSetBindings = struct {
    src_texture: engine.core.pipeline.CombinedImageSampler,
    dst_image: engine.core.pipeline.StorageImage,
}});

const LuminancePipeline = engine.core.pipeline.Pipeline(.{ .shader_path = "hrtsystem/background/luminance.hlsl", .PushSetBindings = struct {
    src_color_image: engine.core.pipeline.SampledImage,
    dst_luminance_image: engine.core.pipeline.StorageImage,
}});

const FoldPipeline = engine.core.pipeline.Pipeline(.{ .shader_path = "hrtsystem/background/fold.hlsl", .PushSetBindings = struct {
    src_mip: engine.core.pipeline.SampledImage,
    dst_mip: engine.core.pipeline.StorageImage,
}});

pub fn create(vc: *const VulkanContext, allocator: std.mem.Allocator) !Self {
    const sampler = try vc.device.createSampler(&.{
        .flags = .{},
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .nearest,
        .address_mode_u = .mirrored_repeat,
        .address_mode_v = .mirrored_repeat,
        .address_mode_w = .mirrored_repeat,
        .mip_lod_bias = 0.0,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 0.0,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .min_lod = 0.0,
        .max_lod = 0.0,
        .border_color = .float_opaque_white,
        .unnormalized_coordinates = vk.FALSE,
    }, null);
    errdefer vc.device.destroySampler(sampler, null);

    var equirectangular_to_equal_area_pipeline = try EquirectangularToEqualAreaPipeline.create(vc, allocator, .{}, .{ sampler }, .{});
    errdefer equirectangular_to_equal_area_pipeline.destroy(vc);

    var luminance_pipeline = try LuminancePipeline.create(vc, allocator, .{}, .{}, .{});
    errdefer luminance_pipeline.destroy(vc);

    var fold_pipeline = try FoldPipeline.create(vc, allocator, .{}, .{}, .{});
    errdefer fold_pipeline.destroy(vc);

    return Self {
        .data = .{},
        .sampler = sampler,
        .equirectangular_to_equal_area_pipeline = equirectangular_to_equal_area_pipeline,
        .luminance_pipeline = luminance_pipeline,
        .fold_pipeline = fold_pipeline,
    };
}

pub fn addDefaultBackground(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder) !void {
    var color = [4]f32 { 1.0, 1.0, 1.0, 1.0 };
    const rgba = Rgba2D {
        .ptr = @ptrCast(&color),
        .extent = .{
            .width = 1,
            .height = 1,
        }
    };
    try self.addBackground(vc, allocator, encoder, rgba, "default white");
}

// this should probably be a parameter, or should infer proper value for this
//
// the equal area map size will be the biggest power of two greater than
// or equal to the equirectangular height, clamped to maximum_equal_area_map_size
const maximum_equal_area_map_size = 16384;
const shader_local_size = 8; // must be kept in sync with shader -- looks like HLSL doesn't support setting this via spec constants

// color_image should be equirectangular, which is converted to equal area.
//
// in "Parameterization-Independent Importance Sampling of Environment Maps",
// the author retains the original environment map for illumination,
// only using equal area for importance sampling.
// I tried that here but it seems to produce noisier results for e.g., sunny skies
// compared to just keeping everything in the same parameterization.
pub fn addBackground(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, color_image: Rgba2D, name: []const u8) !void {
    const equirectangular_extent = color_image.extent;

    const texture_name_equirectangular = try std.fmt.allocPrintZ(allocator, "background {s} equirectangular", .{ name });
    defer allocator.free(texture_name_equirectangular);
    const equirectangular_image = try Image.create(vc, equirectangular_extent, .{ .transfer_dst_bit = true, .sampled_bit = true }, .r32g32b32a32_sfloat, false, texture_name_equirectangular);
    try encoder.attachResource(equirectangular_image);

    const equirectangular_image_host = try encoder.uploadAllocator().alignedAlloc([4]f32, engine.core.vk_helpers.texelBlockSize(.r32g32b32a32_sfloat), color_image.asSlice().len);
    @memcpy(equirectangular_image_host, color_image.asSlice());

    const equal_area_map_size: u32 = @min(std.math.ceilPowerOfTwoAssert(u32, color_image.extent.width), maximum_equal_area_map_size);
    const equal_area_extent = vk.Extent2D { .width = equal_area_map_size, .height = equal_area_map_size };

    const texture_name_equal_area = try std.fmt.allocPrintZ(allocator, "background {s} equal area", .{ name });
    defer allocator.free(texture_name_equal_area);
    const equal_area_image = try Image.create(vc, equal_area_extent, .{ .storage_bit = true, .sampled_bit = true }, .r32g32b32a32_sfloat, false, texture_name_equal_area);
    errdefer equal_area_image.destroy(vc);

    const texture_name_luminance = try std.fmt.allocPrintZ(allocator, "background {s} luminance", .{ name });
    defer allocator.free(texture_name_luminance);
    const luminance_image = try Image.create(vc, equal_area_extent, .{ .storage_bit = true, .sampled_bit = true }, .r32_sfloat, true, texture_name_luminance);
    errdefer luminance_image.destroy(vc);

    const actual_mip_count = std.math.log2(equal_area_map_size) + 1;
    const maximum_mip_count = comptime std.math.log2(maximum_equal_area_map_size) + 1;
    var luminance_mips_views = std.BoundedArray(vk.ImageView, maximum_mip_count) {};
    for (0..actual_mip_count) |level_index| {
        const view = try vc.device.createImageView(&vk.ImageViewCreateInfo {
            .flags = .{},
            .image = luminance_image.handle,
            .view_type = vk.ImageViewType.@"2d",
            .format = .r32_sfloat,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = @intCast(level_index),
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
        }, null);
        try luminance_mips_views.append(view);
        try encoder.attachResource(view);
    }

    // copy equirectangular image to device
    encoder.buffer.pipelineBarrier2(&vk.DependencyInfo {
        .image_memory_barrier_count = 3,
        .p_image_memory_barriers = &[3]vk.ImageMemoryBarrier2 {
            .{
                .dst_stage_mask = .{ .copy_bit = true },
                .dst_access_mask = .{ .transfer_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = equirectangular_image.handle,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            },
            .{
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = equal_area_image.handle,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            },
            .{
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = luminance_image.handle,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = vk.REMAINING_MIP_LEVELS,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            },
        },
    });

    const equirectangular_image_host_slice = encoder.upload_allocator.getBufferSlice(equirectangular_image_host);
    encoder.copyBufferToImage(equirectangular_image_host_slice.handle, equirectangular_image_host_slice.offset, equirectangular_image.handle, .transfer_dst_optimal, equirectangular_extent);

    encoder.buffer.pipelineBarrier2(&vk.DependencyInfo {
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[1]vk.ImageMemoryBarrier2 {
            .{
                .src_stage_mask = .{ .copy_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .old_layout = .transfer_dst_optimal,
                .new_layout = .shader_read_only_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = equirectangular_image.handle,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            },
        },
    });

    // do conversion
    self.equirectangular_to_equal_area_pipeline.recordBindPipeline(encoder.buffer);
    self.equirectangular_to_equal_area_pipeline.recordPushDescriptors(encoder.buffer, .{
        .src_texture = .{ .view = equirectangular_image.view },
        .dst_image = .{ .view = equal_area_image.view },
    });
    const dispatch_size = if (equal_area_map_size > shader_local_size) @divExact(equal_area_map_size, shader_local_size) else 1;
    self.equirectangular_to_equal_area_pipeline.recordDispatch(encoder.buffer, .{ .width = dispatch_size, .height = dispatch_size, .depth = 1 });

    encoder.buffer.pipelineBarrier2(&vk.DependencyInfo {
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[1]vk.ImageMemoryBarrier2 {
            .{
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .old_layout = .general,
                .new_layout = .shader_read_only_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = equal_area_image.handle,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            },
        },
    });

    self.luminance_pipeline.recordBindPipeline(encoder.buffer);
    self.luminance_pipeline.recordPushDescriptors(encoder.buffer, .{
        .src_color_image = .{ .view = equal_area_image.view },
        .dst_luminance_image = .{ .view = luminance_image.view },
    });
    self.luminance_pipeline.recordDispatch(encoder.buffer, .{ .width = dispatch_size, .height = dispatch_size, .depth = 1 });

    self.fold_pipeline.recordBindPipeline(encoder.buffer);
    for (1..luminance_mips_views.len) |dst_mip_level| {
        encoder.buffer.pipelineBarrier2(&vk.DependencyInfo {
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &[1]vk.ImageMemoryBarrier2 {
                .{
                    .src_stage_mask = .{ .compute_shader_bit = true },
                    .src_access_mask = .{ .shader_write_bit = true },
                    .dst_stage_mask = .{ .compute_shader_bit = true },
                    .dst_access_mask = .{ .shader_read_bit = true },
                    .old_layout = .general,
                    .new_layout = .shader_read_only_optimal,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = luminance_image.handle,
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = @intCast(dst_mip_level - 1),
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = vk.REMAINING_ARRAY_LAYERS,
                    },
                }
            },
        });
        self.fold_pipeline.recordPushDescriptors(encoder.buffer, .{
            .src_mip = .{ .view = luminance_mips_views.get(dst_mip_level - 1) },
            .dst_mip = .{ .view = luminance_mips_views.get(dst_mip_level) },
        });
        const dst_mip_size = std.math.pow(u32, 2, @intCast(luminance_mips_views.len - dst_mip_level));
        const mip_dispatch_size = if (dst_mip_size > shader_local_size) @divExact(dst_mip_size, shader_local_size) else 1;
        self.fold_pipeline.recordDispatch(encoder.buffer, .{ .width = mip_dispatch_size, .height = mip_dispatch_size, .depth = 1 });
    }
    encoder.buffer.pipelineBarrier2(&vk.DependencyInfo {
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[1]vk.ImageMemoryBarrier2 {
            .{
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .old_layout = .general,
                .new_layout = .shader_read_only_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = luminance_image.handle,
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = @intCast(luminance_mips_views.len - 1),
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            }
        },
    });

    try self.data.append(allocator, .{
        .rgb_image = equal_area_image,
        .luminance_image = luminance_image,
    });
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    for (self.data.items) |data| {
        data.rgb_image.destroy(vc);
        data.luminance_image.destroy(vc);
    }
    self.data.deinit(allocator);
    self.equirectangular_to_equal_area_pipeline.destroy(vc);
    self.luminance_pipeline.destroy(vc);
    self.fold_pipeline.destroy(vc);
    vc.device.destroySampler(self.sampler, null);
}
