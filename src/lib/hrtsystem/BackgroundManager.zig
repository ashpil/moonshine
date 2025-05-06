const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const toMany = engine.core.vk_helpers.toMany;
const VulkanContext = engine.core.VulkanContext;
const Encoder = engine.core.Encoder;
const Image = engine.core.Image;

const shaders = @import("hrtsystem_shaders");

const Rgba2D = engine.fileformats.exr.helpers.Rgba2D;

images: std.ArrayListUnmanaged(Image),
sampler: vk.Sampler,
equirectangular_to_equal_area_pipeline: EquirectangularToEqualAreaPipeline,
fold_pipeline: FoldPipeline,

const Self = @This();

const EquirectangularToEqualAreaPipeline = engine.core.pipeline.Pipeline(.{
    .shader_source = shaders.equirectangular_to_equal_area,
    .local_size = vk.Extent3D { .width = 8, .height = 8, .depth = 1 },
    .PushSetBindings = struct {
        src_texture: engine.core.pipeline.CombinedImageSampler,
        dst_image: engine.core.pipeline.StorageImage,
    }
});

const FoldPipeline = engine.core.pipeline.Pipeline(.{
    .shader_source = shaders.background_fold,
    .local_size = vk.Extent3D { .width = 8, .height = 8, .depth = 1 },
    .PushSetBindings = struct {
        src_mip: engine.core.pipeline.SampledImage,
        dst_mip: engine.core.pipeline.StorageImage,
    }
});

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

    var fold_pipeline = try FoldPipeline.create(vc, allocator, .{}, .{}, .{});
    errdefer fold_pipeline.destroy(vc);

    return Self {
        .images = .{},
        .sampler = sampler,
        .equirectangular_to_equal_area_pipeline = equirectangular_to_equal_area_pipeline,
        .fold_pipeline = fold_pipeline,
    };
}

pub fn addDefaultBackground(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder) !Handle {
    var color = [4]f32 { 1.0, 1.0, 1.0, 1.0 };
    const rgba = Rgba2D {
        .ptr = toMany(&color),
        .extent = .{
            .width = 1,
            .height = 1,
        }
    };
    return try self.addBackground(vc, allocator, encoder, rgba, "default white");
}

// this should probably be a parameter, or should infer proper value for this
//
// the equal area map size will be the biggest power of two greater than
// or equal to the equirectangular height, clamped to maximum_equal_area_map_size
const maximum_equal_area_map_size = 16384;
const shader_local_size = 8; // must be kept in sync with shader -- looks like HLSL doesn't support setting this via spec constants

pub const Handle = u32;
// color_image should be equirectangular, which is converted to equal area.
//
// in "Parameterization-Independent Importance Sampling of Environment Maps",
// the author retains the original environment map for illumination,
// only using equal area for importance sampling.
// I tried that here but it seems to produce noisier results for e.g., sunny skies
// compared to just keeping everything in the same parameterization.
pub fn addBackground(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, color_image: Rgba2D, name: []const u8) !Handle {
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
    const equal_area_image = try Image.create(vc, equal_area_extent, .{ .storage_bit = true, .sampled_bit = true }, .r32g32b32a32_sfloat, true, texture_name_equal_area);
    errdefer equal_area_image.destroy(vc);

    const actual_mip_count = std.math.log2(equal_area_map_size) + 1;
    const maximum_mip_count = comptime std.math.log2(maximum_equal_area_map_size) + 1;
    var mip_views = std.BoundedArray(vk.ImageView, maximum_mip_count) {};
    for (0..actual_mip_count) |level_index| {
        const view = try vc.device.createImageView(&vk.ImageViewCreateInfo {
            .flags = .{},
            .image = equal_area_image.handle,
            .view_type = vk.ImageViewType.@"2d",
            .format = .r32g32b32a32_sfloat,
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
        try mip_views.append(view);
        try encoder.attachResource(view);
    }

    // copy equirectangular image to device
    encoder.barrier(&[_]Encoder.ImageBarrier {
        .{
            .dst_stage_mask = .{ .copy_bit = true },
            .dst_access_mask = .{ .transfer_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .image = equirectangular_image.handle,
        },
        .{
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .general,
            .image = equal_area_image.handle,
        },
    }, &.{});

    const equirectangular_image_host_slice = encoder.upload_allocator.getBufferSlice(equirectangular_image_host);
    encoder.copyBufferToImage(equirectangular_image_host_slice.handle, equirectangular_image_host_slice.offset, equirectangular_image.handle, .transfer_dst_optimal, equirectangular_extent);

    encoder.barrier(&[_]Encoder.ImageBarrier {
        .{
            .src_stage_mask = .{ .copy_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .image = equirectangular_image.handle,
        },
    }, &.{});

    // do conversion
    self.equirectangular_to_equal_area_pipeline.recordBindPipeline(encoder.buffer);
    self.equirectangular_to_equal_area_pipeline.recordPushDescriptors(encoder.buffer, .{
        .src_texture = .{ .view = equirectangular_image.view },
        .dst_image = .{ .view = equal_area_image.view },
    });
    const dispatch_size = if (equal_area_map_size > shader_local_size) @divExact(equal_area_map_size, shader_local_size) else 1;
    self.equirectangular_to_equal_area_pipeline.recordDispatchWorkgroups(encoder.buffer, .{ .width = dispatch_size, .height = dispatch_size, .depth = 1 });

    self.fold_pipeline.recordBindPipeline(encoder.buffer);
    for (1..mip_views.len) |dst_mip_level| {
        encoder.barrier(&[_]Encoder.ImageBarrier {
            .{
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .old_layout = .general,
                .new_layout = .shader_read_only_optimal,
                .image = equal_area_image.handle,
                .base_mip_level = @intCast(dst_mip_level - 1),
                .level_count = 1,
            },
        }, &.{});
        self.fold_pipeline.recordPushDescriptors(encoder.buffer, .{
            .src_mip = .{ .view = mip_views.get(dst_mip_level - 1) },
            .dst_mip = .{ .view = mip_views.get(dst_mip_level) },
        });
        const dst_mip_size = std.math.pow(u32, 2, @intCast(mip_views.len - dst_mip_level));
        const mip_dispatch_size = if (dst_mip_size > shader_local_size) @divExact(dst_mip_size, shader_local_size) else 1;
        self.fold_pipeline.recordDispatchWorkgroups(encoder.buffer, .{ .width = mip_dispatch_size, .height = mip_dispatch_size, .depth = 1 });
    }
    encoder.barrier(&[_]Encoder.ImageBarrier {
        .{
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .old_layout = .general,
            .new_layout = .shader_read_only_optimal,
            .image = equal_area_image.handle,
            .base_mip_level = @intCast(mip_views.len - 1),
            .level_count = 1,
        },
    }, &.{});

    try self.images.append(allocator, equal_area_image);

    return @intCast(self.images.items.len - 1);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    for (self.images.items) |image| {
        image.destroy(vc);
    }
    self.images.deinit(allocator);
    self.equirectangular_to_equal_area_pipeline.destroy(vc);
    self.fold_pipeline.destroy(vc);
    vc.device.destroySampler(self.sampler, null);
}
