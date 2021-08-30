const vk = @import("vulkan");
const std = @import("std");

const utils = @import("./utils.zig");

const VulkanContext = @import("./VulkanContext.zig");
const F32x3 = @import("../utils/zug.zig").Vec3(f32);
const TransferCommands = @import("./commands.zig").ComputeCommands;

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
    header_10: DDSHeaderDXT10,  // second header

    // just some random sanity checks to make sure we actually are getting a DDS file
    fn verify(self: *const DDSFileInfo) void {
        std.debug.assert(self.magic == 542327876);
        self.header.verify();
    }

    fn getExtent(self: *const DDSFileInfo) vk.Extent2D {
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

    fn isCubemap(self: *const DDSFileInfo) bool {
        return self.header_10.misc_flag == 4;
    }
};

pub const ImageCreateRawInfo = struct {
    extent: vk.Extent2D,
    usage: vk.ImageUsageFlags,
    format: vk.Format,
};

pub const TextureSource = union(enum) {
    filepath: []const u8,
    color: F32x3,
    greyscale: comptime_float,
};

pub fn Images(comptime image_count: comptime_int) type {

    return struct {
        images: [image_count]vk.Image,
        views: [image_count]vk.ImageView,
        memories: [image_count]vk.DeviceMemory,

        const Self = @This();

        pub fn createRaw(vc: *const VulkanContext, info: [image_count]ImageCreateRawInfo) !Self {
            
            var images: [image_count]vk.Image = undefined;
            var views: [image_count]vk.ImageView = undefined;
            var memories: [image_count]vk.DeviceMemory = undefined;

            comptime var i = 0;
            inline while (i < image_count) : (i += 1) {
                const image = try Image.create(vc, info[i].extent, info[i].usage, info[i].format, false);

                images[i] = image.handle;
                views[i] = image.view;
                memories[i] = image.memory;
            }

            return Self {
                .images = images,
                .views = views,
                .memories = memories,
            };
        }

        pub fn createTexture(vc: *const VulkanContext, comptime sources: [image_count]TextureSource, commands: *TransferCommands) !Self {
            var images: [image_count]vk.Image = undefined;
            var views: [image_count]vk.ImageView = undefined;
            var memories: [image_count]vk.DeviceMemory = undefined;

            var extents: [image_count]vk.Extent2D = undefined;
            var bytes: [image_count][]const u8 = undefined;
            var sizes: [image_count]u64 = undefined;
            var is_cubemaps: [image_count]bool = undefined;

            inline for (sources) |source, i| {
                const image = switch (source) {
                    .filepath => |filepath| blk: {
                        const dds_file = @embedFile(filepath);
                        const dds_info = @ptrCast(*const DDSFileInfo, dds_file[0..@sizeOf(DDSFileInfo)]);
                        dds_info.verify(); // this could be comptime but compiler glitches out for some reason
                        extents[i] = dds_info.getExtent();
                        is_cubemaps[i] = dds_info.isCubemap();
                        bytes[i] = dds_file[@sizeOf(DDSFileInfo)..];

                        break :blk try Image.create(vc, extents[i], .{ .transfer_dst_bit = true, .sampled_bit = true }, dds_info.getFormat(), is_cubemaps[i]);
                    },
                    .color => |color| blk: {
                        bytes[i] = comptime std.mem.asBytes(&color);
                        extents[i] = vk.Extent2D {
                            .width = 1,
                            .height = 1,
                        };
                        is_cubemaps[i] = false;
                        
                        break :blk try Image.create(vc, extents[i], .{ .transfer_dst_bit = true, .sampled_bit = true }, .r32g32b32a32_sfloat, false);
                    },
                    .greyscale => |greyscale| blk: {
                        bytes[i] = comptime std.mem.asBytes(&@floatCast(f32, greyscale));
                        extents[i] = vk.Extent2D {
                            .width = 1,
                            .height = 1,
                        };
                        is_cubemaps[i] = false;

                        break :blk try Image.create(vc, extents[i], .{ .transfer_dst_bit = true, .sampled_bit = true }, .r32g32b32a32_sfloat, false);
                    },
                };
                images[i] = image.handle;
                views[i] = image.view;
                memories[i] = image.memory;
                sizes[i] = image.size;
            }

            try commands.uploadDataToImages(vc, image_count, images, bytes, sizes, extents, is_cubemaps);

            return Self {
                .images = images,
                .views = views,
                .memories = memories,
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

        pub fn destroy(self: *const Self, vc: *const VulkanContext) void {
            comptime var i = 0;
            inline while (i < image_count) : (i += 1) {
                vc.device.destroyImageView(self.views[i], null);
                vc.device.destroyImage(self.images[i], null);
                vc.device.freeMemory(self.memories[i], null);
            }
        }
    };
}

const Image = struct {

    handle: vk.Image,
    view: vk.ImageView,
    memory: vk.DeviceMemory,
    size: u64,

    fn create(vc: *const VulkanContext, size: vk.Extent2D, usage: vk.ImageUsageFlags, format: vk.Format, is_cubemap: bool) !Image {
        const extent = vk.Extent3D {
            .width = size.width,
            .height = size.height,
            .depth = 1,
        };

        const handle = try vc.device.createImage(.{
            .flags = if (is_cubemap) .{ .cube_compatible_bit = true } else .{},
            .image_type = .@"2d",
            .format = format,
            .extent = extent,
            .mip_levels = 1,
            .array_layers = if (is_cubemap) 6 else 1,
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
            .view_type = if (is_cubemap) .cube else .@"2d",
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

        return Image {
            .memory = memory,
            .handle = handle,
            .view = view,
            .size = mem_requirements.size,
        };
    }
};