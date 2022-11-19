// at top level this just has ziggified C API -- but also have a higher-level helpers namespace

const c = @import("../c.zig");
const std = @import("std");

pub const TinyExrError = error {
    InvalidMagicNumber,
    InvalidExrVersion,
    InvalidArgument,
    InvalidData,
    InvalidFile,
    InvalidParameter,
    CantOpenFile,
    UnsupportedFormat,
    InvalidHeader,
    UnsupportedFeature,
    CantWriteFile,
    SerializationFailed,
    LayerNotFound,
    DataTooLarge,
};

pub const Image = c.EXRImage;
pub const Header = c.EXRHeader;
pub const ChannelInfo = c.EXRChannelInfo;

pub const PixelType = enum(c_int) {
    uint = 0,
    half = 1,
    float = 2,
};

fn getErr(err_code: c_int) TinyExrError!void {
    return switch (err_code) {
        0 => {},
        -1 => TinyExrError.InvalidMagicNumber,
        -2 => TinyExrError.InvalidExrVersion,
        -3 => TinyExrError.InvalidArgument,
        -4 => TinyExrError.InvalidData,
        -5 => TinyExrError.InvalidFile,
        -6 => TinyExrError.InvalidParameter,
        -7 => TinyExrError.CantOpenFile,
        -8 => TinyExrError.UnsupportedFormat,
        -9 => TinyExrError.InvalidHeader,
        -10 => TinyExrError.UnsupportedFeature,
        -11 => TinyExrError.CantWriteFile,
        -12 => TinyExrError.SerializationFailed,
        -13 => TinyExrError.LayerNotFound,
        -14 => TinyExrError.DataTooLarge,
        else => unreachable,
    };
}

pub fn saveExrImageToFile(image: *const Image, header: *const Header, filename: [*:0]const u8) TinyExrError!void {
    var err_message: [*c]u8 = null;
    getErr(c.SaveEXRImageToFile(image, header, filename, &err_message)) catch |err| {
        std.log.err("tinyexr: {}: {s}", .{ err, err_message });
        c.FreeEXRErrorMessage(err_message);
        return err;
    };
}

pub fn initExrHeader(header: *Header) void {
    c.InitEXRHeader(header);
}

pub fn initExrImage(image: *Image) void {
    c.InitEXRImage(image);
}

pub const helpers = struct {
    const vk = @import("vulkan");

    // make out_filename this not sentinel terminated
    pub fn save(allocator: std.mem.Allocator, packed_channels: []const f32, packed_channel_count: u32, size: vk.Extent2D, out_filename: [*:0]const u8) (TinyExrError || std.mem.Allocator.Error)!void {
        const channel_count = 3;

        var header: Header = undefined;
        initExrHeader(&header);

        var image: Image = undefined;
        initExrImage(&image);

        const pixel_count = size.width * size.height;

        const ImageChannels = std.MultiArrayList(struct {
            r: f32,
            g: f32,
            b: f32,
        });
        var image_channels = ImageChannels {};
        defer image_channels.deinit(allocator);

        try image_channels.ensureUnusedCapacity(allocator, pixel_count);

        {
            var i: usize = 0;
            while (i < pixel_count) : (i += 1) {
                image_channels.appendAssumeCapacity(.{
                    .r = packed_channels[packed_channel_count * i + 0],
                    .g = packed_channels[packed_channel_count * i + 1],
                    .b = packed_channels[packed_channel_count * i + 2],
                });
            }
        }

        const image_channels_slice = image_channels.slice();
        image.num_channels = channel_count;
        image.images = &[3][*c]u8 {
            image_channels_slice.ptrs[2],
            image_channels_slice.ptrs[1],
            image_channels_slice.ptrs[0],
        };
        image.width = @intCast(c_int, size.width);
        image.height = @intCast(c_int, size.height);

        var header_channels = try allocator.alloc(ChannelInfo, channel_count);
        defer allocator.free(header_channels);

        var pixel_types = try allocator.alloc(c_int, channel_count);
        defer allocator.free(pixel_types);
        var requested_pixel_types = try allocator.alloc(c_int, channel_count);
        defer allocator.free(requested_pixel_types);

        header.num_channels = channel_count;
        header.channels = header_channels.ptr;

        header.channels[0].name[0] = 'B';
        header.channels[0].name[1] = 0;
        header.channels[1].name[0] = 'G';
        header.channels[1].name[1] = 0;
        header.channels[2].name[0] = 'R';
        header.channels[2].name[1] = 0;

        header.pixel_types = pixel_types.ptr;
        header.requested_pixel_types = requested_pixel_types.ptr;

        {
            comptime var i: usize = 0;
            inline while (i < channel_count) : (i += 1) {
                header.pixel_types[i] = @enumToInt(PixelType.float);
                header.requested_pixel_types[i] = @enumToInt(PixelType.float);
            }
        }

        try saveExrImageToFile(&image, &header, out_filename);
    }
};
