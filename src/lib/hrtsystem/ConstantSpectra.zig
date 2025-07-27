const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const Image = core.Image;
const vk_helpers = core.vk_helpers;

const F32x2 = engine.vector.Vec2(f32);
const F32x3 = engine.vector.Vec3(f32);
const F32x4 = engine.vector.Vec4(f32);

const color = engine.color;

pub const DescriptorLayout = core.descriptor.DescriptorLayout(&.{
    .{
        .descriptor_type = .sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true, .compute_bit = true },
    },
    .{
        .descriptor_type = .sampled_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true, .compute_bit = true },
    },
    .{
        .descriptor_type = .sampled_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true, .compute_bit = true },
    },
    .{
        .descriptor_type = .sampled_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true, .compute_bit = true },
    },
    .{
        .descriptor_type = .sampled_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true, .compute_bit = true },
    },
    .{
        .descriptor_type = .sampled_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true, .compute_bit = true },
    },
    .{
        .descriptor_type = .sampled_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true, .compute_bit = true },
    },
    .{
        .descriptor_type = .sampled_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true, .compute_bit = true },
    },
}, .{}, 1, "Constant Spectra");

const Self = @This();

descriptor_layout: DescriptorLayout,
descriptor_set: vk.DescriptorSet,
sampler: vk.Sampler,
cie_x: Image,
cie_y: Image,
cie_z: Image,
mallet_bt709_r: Image,
mallet_bt709_g: Image,
mallet_bt709_b: Image,
d65: Image,

fn createSpectrumImage(vc: *const VulkanContext, encoder: *Encoder, descriptor_set: vk.DescriptorSet, dst_binding: u32, spectrum: color.TabulatedSpectrum, name: [:0]const u8) !Image {
    const extent = vk.Extent2D {
        .width = @intCast(spectrum.data.len),
        .height = 1,
    };
    const image = try Image.create(vc, extent, .{ .transfer_dst_bit = true, .sampled_bit = true }, .r32_sfloat, false, name);

    const data_staging = try encoder.uploadAllocator().alloc(f32, spectrum.data.len);
    for (data_staging, spectrum.data) |*datum_staging, datum| {
        datum_staging.* = @floatCast(datum);
    }

    encoder.uploadDataToImage(f32, encoder.upload_allocator.getBufferSlice(data_staging), image.handle, extent, .shader_read_only_optimal);

    vc.device.updateDescriptorSets(1, (&vk.WriteDescriptorSet {
        .dst_set = descriptor_set,
        .dst_binding = dst_binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .sampled_image,
        .p_image_info = (&vk.DescriptorImageInfo {
            .image_layout = .shader_read_only_optimal,
            .image_view = image.view,
            .sampler = .null_handle,
        })[0..1],
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    })[0..1], 0, null);

    return image;
}

pub fn create(vc: *const VulkanContext, encoder: *Encoder) !Self {
    const sampler = try vc.device.createSampler(&.{
        .flags = .{},
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_border,
        .address_mode_v = .clamp_to_border,
        .address_mode_w = .clamp_to_border,
        .mip_lod_bias = 0.0,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 0.0,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .min_lod = 0.0,
        .max_lod = 0.0,
        .border_color = .float_opaque_black,
        .unnormalized_coordinates = vk.FALSE,
    }, null);

    const descriptor_layout = try DescriptorLayout.create(vc, .{ sampler });

    var descriptor_set: vk.DescriptorSet = undefined;
    try vc.device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo {
        .descriptor_pool = descriptor_layout.pool,
        .descriptor_set_count = 1,
        .p_set_layouts = (&descriptor_layout.handle)[0..1],
    }, (&descriptor_set)[0..1]);
    try vk_helpers.setDebugName(vc.device, descriptor_set, "Constant Spectra");

    const cie_x = try createSpectrumImage(vc, encoder, descriptor_set, 1, color.cie_1931.x, "cie x");
    const cie_y = try createSpectrumImage(vc, encoder, descriptor_set, 2, color.cie_1931.y, "cie y");
    const cie_z = try createSpectrumImage(vc, encoder, descriptor_set, 3, color.cie_1931.z, "cie z");
    const mallet_bt709_r = try createSpectrumImage(vc, encoder, descriptor_set, 4, color.mallet_bt709.r, "mallet bt709 r");
    const mallet_bt709_g = try createSpectrumImage(vc, encoder, descriptor_set, 5, color.mallet_bt709.g, "mallet bt709 g");
    const mallet_bt709_b = try createSpectrumImage(vc, encoder, descriptor_set, 6, color.mallet_bt709.b, "mallet bt709 b");
    const d65 = try createSpectrumImage(vc, encoder, descriptor_set, 7, color.illuminants.d65, "illuminant d65");

    return Self {
        .descriptor_layout = descriptor_layout,
        .descriptor_set = descriptor_set,
        .sampler = sampler,
        .cie_x = cie_x,
        .cie_y = cie_y,
        .cie_z = cie_z,
        .mallet_bt709_r = mallet_bt709_r,
        .mallet_bt709_g = mallet_bt709_g,
        .mallet_bt709_b = mallet_bt709_b,
        .d65 = d65,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.descriptor_layout.destroy(vc);
    vc.device.destroySampler(self.sampler, null);
    self.cie_x.destroy(vc);
    self.cie_y.destroy(vc);
    self.cie_z.destroy(vc);
    self.mallet_bt709_r.destroy(vc);
    self.mallet_bt709_g.destroy(vc);
    self.mallet_bt709_b.destroy(vc);
    self.d65.destroy(vc);
}
