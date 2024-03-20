const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const VulkanContext = engine.core.VulkanContext;
const Commands = engine.core.Commands;
const VkAllocator = engine.core.Allocator;
const Image = engine.core.Image;

const AliasTable = @import("./alias_table.zig").NormalizedAliasTable;

const Rgba2D = engine.fileformats.exr.helpers.Rgba2D;

data: std.ArrayListUnmanaged(struct {
    alias_table: VkAllocator.DeviceBuffer(AliasTable.TableEntry),
    image: Image,
}),
sampler: vk.Sampler,
equirectangular_to_equal_area_pipeline: EquirectangularToEqualAreaPipeline,
luminance_pipeline: LuminancePipeline,

const Self = @This();

fn luminance(rgb: [3]f32) f32 {
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}

const EquirectangularToEqualAreaPipeline = engine.core.pipeline.Pipeline("background/equirectangular_to_equal_area.hlsl", struct {}, struct {},
&.{
    .{
        .name = "src_texture",
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .compute_bit = true },
    },
    .{
        .name = "dst_image",
        .descriptor_type = .storage_image,
        .descriptor_count = 1,
        .stage_flags = .{ .compute_bit = true },
    },
});

const LuminancePipeline = engine.core.pipeline.Pipeline("background/luminance.hlsl", struct {}, struct {},
&.{
    .{
        .name = "src_color_image",
        .descriptor_type = .sampled_image,
        .descriptor_count = 1,
        .stage_flags = .{ .compute_bit = true },
    },
    .{
        .name = "dst_luminance_image",
        .descriptor_type = .storage_image,
        .descriptor_count = 1,
        .stage_flags = .{ .compute_bit = true },
    },
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

    var equirectangular_to_equal_area_pipeline = try EquirectangularToEqualAreaPipeline.create(vc, allocator, .{}, .{ sampler });
    errdefer equirectangular_to_equal_area_pipeline.destroy(vc);

    var luminance_pipeline = try LuminancePipeline.create(vc, allocator, .{}, .{});
    errdefer luminance_pipeline.destroy(vc);

    return Self {
        .data = .{},
        .sampler = sampler,
        .equirectangular_to_equal_area_pipeline = equirectangular_to_equal_area_pipeline,
        .luminance_pipeline = luminance_pipeline,
    };
}

pub fn addDefaultBackground(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands) !void {
    var color = [4]f32 { 1.0, 1.0, 1.0, 1.0 };
    const rgba = Rgba2D {
        .ptr = @ptrCast(&color),
        .extent = .{
            .width = 1,
            .height = 1,
        }
    };
    try self.addBackground(vc, vk_allocator, allocator, commands, rgba, "default white");
}

// this should probably be a parameter, or should infer proper value for this
//
// the equal area map size will be the biggest power of two smaller than
// or equal to the equirectangular height, clamped to maximum_equal_area_map_size
const maximum_equal_area_map_size = 1024;
const shader_local_size = 8; // must be kept in sync with shader -- looks like HLSL doesn't support setting this via spec constants

// color_image should be equirectangular, which is converted to equal area.
//
// in "Parameterization-Independent Importance Sampling of Environment Maps",
// the author retains the original environment map for illumination,
// only using equal area for importance sampling.
// I tried that here but it seems to produce noisier results for e.g., sunny skies
// compared to just keeping everything in the same parameterization.
pub fn addBackground(self: *Self, vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, color_image: Rgba2D, name: []const u8) !void {
    const texture_name = try std.fmt.allocPrintZ(allocator, "background {s}", .{ name });
    defer allocator.free(texture_name);

    const equirectangular_extent = color_image.extent;
    const equirectangular_image = try Image.create(vc, vk_allocator, equirectangular_extent, .{ .transfer_dst_bit = true, .sampled_bit = true }, .r32g32b32a32_sfloat, false, texture_name);
    defer equirectangular_image.destroy(vc);

    const equirectangular_image_host = try vk_allocator.createHostBuffer(vc, [4]f32, @intCast(color_image.asSlice().len), .{ .transfer_src_bit = true });
    defer equirectangular_image_host.destroy(vc);
    @memcpy(equirectangular_image_host.data, color_image.asSlice());

    const equal_area_map_size: u32 = @min(std.math.floorPowerOfTwo(u32, color_image.extent.height), maximum_equal_area_map_size);
    const equal_area_extent = vk.Extent2D { .width = equal_area_map_size, .height = equal_area_map_size };

    const equal_area_image = try Image.create(vc, vk_allocator, equal_area_extent, .{ .storage_bit = true, .transfer_src_bit = true, .sampled_bit = true }, .r32g32b32a32_sfloat, false, texture_name);
    errdefer equal_area_image.destroy(vc);

    const luminance_image_gpu = try Image.create(vc, vk_allocator, equal_area_extent, .{ .transfer_src_bit = true, .storage_bit = true }, .r32_sfloat, false, texture_name);
    defer luminance_image_gpu.destroy(vc);
    const luminance_image_host = try vk_allocator.createHostBuffer(vc, f32, equal_area_map_size * equal_area_map_size, .{ .transfer_dst_bit = true });
    defer luminance_image_host.destroy(vc);

    try commands.startRecording(vc);

    // copy equirectangular image to device
    vc.device.cmdPipelineBarrier2(commands.buffer, &vk.DependencyInfo {
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
                .image = luminance_image_gpu.handle,
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
    vc.device.cmdCopyBufferToImage(commands.buffer, equirectangular_image_host.handle, equirectangular_image.handle, .transfer_dst_optimal, 1, @ptrCast(&vk.BufferImageCopy {
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
            .width = equirectangular_extent.width,
            .height = equirectangular_extent.height,
            .depth = 1,
        },
    }));

    vc.device.cmdPipelineBarrier2(commands.buffer, &vk.DependencyInfo {
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
    self.equirectangular_to_equal_area_pipeline.recordBindPipeline(vc, commands.buffer);
    self.equirectangular_to_equal_area_pipeline.recordPushDescriptors(vc, commands.buffer, .{
        .src_texture = equirectangular_image.view,
        .dst_image = equal_area_image.view,
    });
    const dispatch_size = if (equal_area_map_size > shader_local_size) @divExact(equal_area_map_size, shader_local_size) else 1;
    self.equirectangular_to_equal_area_pipeline.recordDispatch(vc, commands.buffer, .{ .width = dispatch_size, .height = dispatch_size, .depth = 1 });

    vc.device.cmdPipelineBarrier2(commands.buffer, &vk.DependencyInfo {
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

    self.luminance_pipeline.recordBindPipeline(vc, commands.buffer);
    self.luminance_pipeline.recordPushDescriptors(vc, commands.buffer, .{
        .src_color_image = equal_area_image.view,
        .dst_luminance_image = luminance_image_gpu.view,
    });
    self.luminance_pipeline.recordDispatch(vc, commands.buffer, .{ .width = dispatch_size, .height = dispatch_size, .depth = 1 });

    // copy luminance image to host
    vc.device.cmdPipelineBarrier2(commands.buffer, &vk.DependencyInfo {
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&vk.ImageMemoryBarrier2 {
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = .{ .shader_write_bit = true },
            .dst_stage_mask = .{ .copy_bit = true },
            .dst_access_mask = .{ .transfer_read_bit = true },
            .old_layout = .general,
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = luminance_image_gpu.handle,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
        }),
    });
    vc.device.cmdCopyImageToBuffer(commands.buffer, luminance_image_gpu.handle, .transfer_src_optimal, luminance_image_host.handle, 1, @ptrCast(&vk.BufferImageCopy {
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
            .width = equal_area_map_size,
            .height = equal_area_map_size,
            .depth = 1,
        },
    }));
    try commands.submitAndIdleUntilDone(vc);

    const alias_table = blk: {
        const buffer = try vk_allocator.createDeviceBuffer(vc, allocator, AliasTable.TableEntry, equal_area_map_size * equal_area_map_size, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
        errdefer buffer.destroy(vc);

        const table = try AliasTable.create(allocator, luminance_image_host.data);
        defer allocator.free(table.entries);

        try commands.uploadData(AliasTable.TableEntry, vc, vk_allocator, buffer, table.entries);

        break :blk buffer;
    };
    errdefer alias_table.destroy(vc);

    try self.data.append(allocator, .{
        .image = equal_area_image,
        .alias_table = alias_table,
    });
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    for (self.data.items) |data| {
        data.alias_table.destroy(vc);
        data.image.destroy(vc);
    }
    self.data.deinit(allocator);
    self.equirectangular_to_equal_area_pipeline.destroy(vc);
    self.luminance_pipeline.destroy(vc);
    vc.device.destroySampler(self.sampler, null);
}
