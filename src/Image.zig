const vk = @import("vulkan");
const std = @import("std");

const VulkanContext = @import("./VulkanContext.zig");
const TransferCommands = @import("./commands.zig").ComputeCommands;
const F32x3 = @import("./zug.zig").Vec3(f32);

const utils = @import("./utils.zig");

handle: vk.Image,
view: vk.ImageView,
memory: vk.DeviceMemory,

const Self = @This();

// https://docs.microsoft.com/en-us/windows/win32/direct3ddds/dx-graphics-dds-reference
const DDSPixelFormat = extern struct {
    size: u32,                  // expected to be 32
    flags: u32,                 // flags for pixel format
    four_cc: u32,               // four characters indicating format type - for us, expected to be "DX10"
    rgb_bit_count: u32,         // "Number of bits in an RGB (possibly including alpha) format"
    r_bit_mask: u32,            // mask for red data
    g_bit_mask: u32,            // mask for green data
    b_bit_mask: u32,            // mask for blue data
    a_bit_mask: u32,            // mask for alpha data

    fn verify(self: *const DDSPixelFormat) void {
        std.debug.assert(self.size == 32);
        std.debug.assert(self.four_cc == @ptrCast(*const u32, "DX10").*);
    }
};

const DDSHeader = extern struct {
    size: u32,                  // expected to be 124
    flags: u32,                 // flags indicating which fields below have valid data
    height: u32,                // height of image
    width: u32,                 // width of image
    pitch_or_linear_size: u32,  // "The pitch or number of bytes per scan line in an uncompressed texture"
    depth: u32,                 // depth of image
    mip_map_count: u32,         // number of mipmaps in image
    reserved_1: [11]u32,        // unused
    ddspf: DDSPixelFormat,      // details about pixels
    caps: u32,                  // "Specifies the complexity of the surfaces stored."
    caps2: u32,                 // "Additional detail about the surfaces stored."
    caps3: u32,                 // unused
    caps4: u32,                 // unused
    reserved_2: u32,            // unused

    fn verify(self: *const DDSHeader) void {
        std.debug.assert(self.size == 124);
        self.ddspf.verify();
    }
};

const DDSHeaderDXT10 = extern struct {
    dxgi_format: u32,           // the surface pixel format; this should probably be an enum
    resource_dimension: u32,    // texture dimension
    misc_flag: u32,             // misc flags
    array_size: u32,            // number of elements in array
    misc_flags_2: u32,          // additional metadata
};

const DDSFileInfo = extern struct {
    magic: u32,                 // expected to be 542327876, hex for "DDS"
    header: DDSHeader,          // first header
    header_10: DDSHeaderDXT10,   // second header

    // just some random sanity checks to make sure we actually are getting a DDS file
    fn verify(self: *const DDSFileInfo) void {
        std.debug.assert(self.magic == 542327876);
        self.header.verify();
    }

    fn getSize(self: *const DDSFileInfo) vk.Extent2D {
        return vk.Extent2D {
            .width = self.header.width,
            .height = self.header.height,
        };
    }

    fn getFormat(self: *const DDSFileInfo) vk.Format {
        return switch (self.header_10.dxgi_format) {
            71 => .bc1_rgb_srgb_block,
            80 => .bc4_unorm_block,
            83 => .bc5_unorm_block,
            else => unreachable, // TODO
        };
    }
};

pub fn createTexture(vc: *const VulkanContext, commands: *TransferCommands, comptime path: []const u8) !Self {
    const dds_file = @embedFile(path);
    const dds_info = @ptrCast(*const DDSFileInfo, dds_file[0..148]);
    dds_info.verify(); // this could be comptime but compiler glitches out for some reason
    const size = dds_info.getSize();
    const format = dds_info.getFormat();
    const image_bytes = dds_file[148..];

    var image_size: u64 = undefined;
    const image = try create(vc, size, .{ .transfer_dst_bit = true, .sampled_bit = true }, format, &image_size);

    // TODO: this should be a compute command of its own, as well as same for cube map
    try commands.transitionImageLayout(vc, image.handle, .@"undefined", .transfer_dst_optimal);

    var staging_buffer: vk.Buffer = undefined;
    var staging_buffer_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, image_size, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &staging_buffer, &staging_buffer_memory);
    defer vc.device.destroyBuffer(staging_buffer, null);
    defer vc.device.freeMemory(staging_buffer_memory, null);

    const dst = @ptrCast([*]u8, (try vc.device.mapMemory(staging_buffer_memory, 0, image_size, .{})).?);
    std.mem.copy(u8, dst[0..image_size], image_bytes);
    vc.device.unmapMemory(staging_buffer_memory);
    try commands.copyBufferToImage(vc, staging_buffer, image.handle, size.width, size.height, 1);
    try commands.transitionImageLayout(vc, image.handle, .transfer_dst_optimal, .shader_read_only_optimal);

    return image;
}

pub fn create(vc: *const VulkanContext, size: vk.Extent2D, comptime usage: vk.ImageUsageFlags, format: vk.Format, maybe_image_final_size: ?*u64) !Self {
    const extent = vk.Extent3D {
        .width = size.width,
        .height = size.height,
        .depth = 1,
    };

    const handle = try vc.device.createImage(.{
        .flags = .{},
        .image_type = .@"2d",
        .format = format,
        .extent = extent,
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .@"undefined",
    }, null);
    errdefer vc.device.destroyImage(handle, null);

    const mem_requirements = vc.device.getImageMemoryRequirements(handle);

    const memory = try vc.device.allocateMemory(.{
        .allocation_size = mem_requirements.size,
        .memory_type_index = try utils.findMemoryType(vc, mem_requirements.memory_type_bits, .{ .device_local_bit = true }),
    }, null);
    errdefer vc.device.freeMemory(memory, null);

    try vc.device.bindImageMemory(handle, memory, 0);

    const view = try vc.device.createImageView(.{
        .flags = .{},
        .image = handle,
        .view_type = .@"2d",
        .format = format, 
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);
    errdefer vc.device.destroyImageView(view, null);

    if (maybe_image_final_size) |image_final_size| {
        image_final_size.* = mem_requirements.size;
    }

    return Self {
        .memory = memory,
        .handle = handle,
        .view = view,
    };
}

pub fn createSampler(vc: *const VulkanContext) !vk.Sampler {
    return try vc.device.createSampler(.{
        .flags = .{},
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
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
}

pub fn createTombstone(vc: *const VulkanContext, commands: *TransferCommands, color: anytype) !Self {
    const size = 16;
    const color_bytes = switch(@TypeOf(color)) {
        F32x3, f32 => std.mem.asBytes(&color),
        comptime_float => std.mem.asBytes(&@floatCast(f32, color)),
        else => unreachable, // TODO if we need more types here
    };

    const image = try create(vc, .{ .width = 1, .height = 1 }, .{ .transfer_dst_bit = true, .sampled_bit = true }, .r32g32b32a32_sfloat, null);

    // TODO: this should be a compute command of its own, as well as same for cube map
    try commands.transitionImageLayout(vc, image.handle, .@"undefined", .transfer_dst_optimal);

    var staging_buffer: vk.Buffer = undefined;
    var staging_buffer_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, size, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &staging_buffer, &staging_buffer_memory);
    defer vc.device.destroyBuffer(staging_buffer, null);
    defer vc.device.freeMemory(staging_buffer_memory, null);

    const dst = @ptrCast([*]u8, (try vc.device.mapMemory(staging_buffer_memory, 0, size, .{})).?);
    std.mem.copy(u8, dst[0..size], color_bytes);
    vc.device.unmapMemory(staging_buffer_memory);
    try commands.copyBufferToImage(vc, staging_buffer, image.handle, 1, 1, 1);
    try commands.transitionImageLayout(vc, image.handle, .transfer_dst_optimal, .shader_read_only_optimal);
    return image;
}

pub fn createCubeMap(vc: *const VulkanContext, commands: *TransferCommands, comptime texture_dir: []const u8, comptime size: comptime_int) !Self {
    var textures: [6]*const [size * size / 2]u8 = undefined;
    const names = .{
        "right.dds",
        "left.dds",
        "top.dds",
        "bottom.dds",
        "front.dds",
        "back.dds",
    };
    comptime for (names) |name, i| {
        textures[i] = @embedFile(texture_dir ++ name)[148..];
    };
    const extent = vk.Extent3D {
        .width = @intCast(u32, size),
        .height = @intCast(u32, size),
        .depth = 1,
    };
    const format = .bc1_rgb_srgb_block;  // this might need to be variable

    const handle = try vc.device.createImage(.{
        .flags = .{ .cube_compatible_bit = true },
        .image_type = .@"2d",
        .format = format,
        .extent = extent,
        .mip_levels = 1,
        .array_layers = 6,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .sampled_bit = true, .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .@"undefined",
    }, null);
    errdefer vc.device.destroyImage(handle, null);

    const mem_requirements = vc.device.getImageMemoryRequirements(handle);

    const memory = try vc.device.allocateMemory(.{
        .allocation_size = mem_requirements.size,
        .memory_type_index = try utils.findMemoryType(vc, mem_requirements.memory_type_bits, .{ .device_local_bit = true }),
    }, null);
    errdefer vc.device.freeMemory(memory, null);

    try vc.device.bindImageMemory(handle, memory, 0);

    const view = try vc.device.createImageView(.{
        .flags = .{},
        .image = handle,
        .view_type = .cube,
        .format = format, 
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = vk.REMAINING_ARRAY_LAYERS,
        },
    }, null);
    errdefer vc.device.destroyImageView(view, null);

    try commands.transitionImageLayout(vc, handle, .@"undefined", .transfer_dst_optimal);

    var staging_buffer: vk.Buffer = undefined;
    var staging_buffer_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, mem_requirements.size, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true }, &staging_buffer, &staging_buffer_memory);
    defer vc.device.destroyBuffer(staging_buffer, null);
    defer vc.device.freeMemory(staging_buffer_memory, null);

    const dst = @ptrCast([*]u8, (try vc.device.mapMemory(staging_buffer_memory, 0, mem_requirements.size, .{})).?);
    const layer_size = mem_requirements.size / 6;
    inline for (names) |_, i| {
        std.mem.copy(u8, dst[layer_size * i..layer_size * (i + 1)], textures[i]);
    }
    vc.device.unmapMemory(staging_buffer_memory);
    try commands.copyBufferToImage(vc, staging_buffer, handle, size, size, 6);
    try commands.transitionImageLayout(vc, handle, .transfer_dst_optimal, .shader_read_only_optimal);

    return Self {
        .memory = memory,
        .handle = handle,
        .view = view,
    };
}

pub fn destroy(self: *const Self, vc: *const VulkanContext) void {
    vc.device.destroyImageView(self.view, null);
    vc.device.destroyImage(self.handle, null);
    vc.device.freeMemory(self.memory, null);
}