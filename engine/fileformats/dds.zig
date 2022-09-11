const vk = @import("vulkan");
const std = @import("std");

// https://docs.microsoft.com/en-us/windows/win32/direct3ddds/dx-graphics-dds-reference
pub const PixelFormat = extern struct {
    size: u32,                  // expected to be 32
    flags: u32,                 // flags for pixel format
    four_cc: u32,               // four characters indicating format type - for us, expected to be "DX10"
    rgb_bit_count: u32,         // "Number of bits in an RGB (possibly including alpha) format"
    r_bit_mask: u32,            // mask for red data
    g_bit_mask: u32,            // mask for green data
    b_bit_mask: u32,            // mask for blue data
    a_bit_mask: u32,            // mask for alpha data

    fn verify(self: *const PixelFormat) void {
        std.debug.assert(self.size == 32);
        std.debug.assert(self.four_cc == @ptrCast(*const u32, "DX10").*);
    }
};

pub const Header = extern struct {
    size: u32,                  // expected to be 124
    flags: u32,                 // flags indicating which fields below have valid data
    height: u32,                // height of image
    width: u32,                 // width of image
    pitch_or_linear_size: u32,  // "The pitch or number of bytes per scan line in an uncompressed texture"
    depth: u32,                 // depth of image
    mip_map_count: u32,         // number of mipmaps in image
    reserved_1: [11]u32,        // unused
    ddspf: PixelFormat,      // details about pixels
    caps: u32,                  // "Specifies the complexity of the surfaces stored."
    caps2: u32,                 // "Additional detail about the surfaces stored."
    caps3: u32,                 // unused
    caps4: u32,                 // unused
    reserved_2: u32,            // unused

    fn verify(self: *const Header) void {
        std.debug.assert(self.size == 124);
        self.ddspf.verify();
    }
};

pub const HeaderDXT10 = extern struct {
    dxgi_format: u32,           // the surface pixel format; this should probably be an enum
    resource_dimension: u32,    // texture dimension
    misc_flag: u32,             // misc flags
    array_size: u32,            // number of elements in array
    misc_flags_2: u32,          // additional metadata
};

pub const FileInfo = extern struct {
    magic: u32,                 // expected to be 542327876, hex for "DDS"
    header: Header,          // first header
    header_10: HeaderDXT10,  // second header

    // just some random sanity checks to make sure we actually are getting a DDS file
    pub fn verify(self: *const FileInfo) void {
        std.debug.assert(self.magic == 542327876);
        self.header.verify();
    }

    pub fn getExtent(self: *const FileInfo) vk.Extent2D {
        return vk.Extent2D {
            .width = self.header.width,
            .height = self.header.height,
        };
    }

    pub fn getFormat(self: *const FileInfo) vk.Format {
        return switch (self.header_10.dxgi_format) {
            71 => .bc1_rgb_srgb_block,
            80 => .bc4_unorm_block,
            83 => .bc5_unorm_block,
            95 => .bc6h_ufloat_block,
            96 => .bc6h_sfloat_block,
            else => unreachable, // TODO
        };
    }

    pub fn isCubemap(self: *const FileInfo) bool {
        return self.header_10.misc_flag == 4;
    }
};