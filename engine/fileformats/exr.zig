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
pub const Version = c.EXRVersion;
pub const ChannelInfo = c.EXRChannelInfo;

pub const PixelType = enum(c_int) {
    uint = 0,
    half = 1,
    float = 2,
};

fn intToStatus(err_code: c_int) TinyExrError!void {
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

pub fn RetType(comptime T: type) type {
    return switch (@typeInfo(T).Fn.return_type.?) {
        c_int => void,
        usize => usize,
        else => unreachable, // TODO
    };
}

pub fn handleError(func: anytype, args: anytype) TinyExrError!RetType(@TypeOf(func)) {
    var err_message: [*c]u8 = undefined;
    const ref = &err_message;
    const new_args = args ++ .{ ref };
    switch (@typeInfo(@TypeOf(func)).Fn.return_type.?) {
        c_int => intToStatus(@call(.auto, func, new_args)) catch |err| {
            std.log.err("tinyexr: {}: {s}", .{ err, err_message });
            c.FreeEXRErrorMessage(err_message);
            return err;
        },
        usize => {
            const n = @call(.auto, func, new_args);
            if (n == 0) {
                std.log.err("tinyexr: {s}", .{ err_message });
                c.FreeEXRErrorMessage(err_message);
                return TinyExrError.InvalidData; // want to return some sort of error here but not sure what
            } else return n;
        },
        else => comptime unreachable,
    }
}

pub fn saveExrImageToFile(image: *const Image, header: *const Header, filename: [*:0]const u8) TinyExrError!void {
    return handleError(c.SaveEXRImageToFile, .{ image, header, filename });
}

pub fn saveEXRImageToMemory(image: *const Image, header: *const Header, memory: *[*c]u8) TinyExrError!usize {
    return handleError(c.SaveEXRImageToMemory, .{ image, header, memory });
}

pub fn loadExrImageFromFile(image: *Image, header: *const Header, filename: [*:0]const u8) TinyExrError!void {
    return handleError(c.LoadExrImageFromFile, .{ image, header, filename });
}

pub fn parseExrHeaderFromFile(header: *Header, version: *const Version, filename: [*:0]const u8) TinyExrError!void {
    return handleError(c.ParseEXRHeaderFromFile, .{ header, version, filename });
}

pub fn parseExrVersionFromFile(version: *Version, filename: [*:0]const u8) TinyExrError!void {
    return intToStatus(c.ParseEXRVersionFromFile(version, filename));
}

pub fn loadEXR(out_rgba: *[*c]f32, width: *c_int, height: *c_int, filename: [*:0]const u8) TinyExrError!void {
    return handleError(c.LoadEXR, .{ out_rgba, width, height, filename });
}

pub fn loadEXRFromMemory(out_rgba: *[*c]f32, width: *c_int, height: *c_int, memory: [*]const u8, size: usize) TinyExrError!void {
    return handleError(c.LoadEXRFromMemory, .{ out_rgba, width, height, memory, size });
}

pub fn initExrHeader(header: *Header) void {
    c.InitEXRHeader(header);
}

pub fn initExrImage(image: *Image) void {
    c.InitEXRImage(image);
}

// things that don't actually correspond to things in tinyexr but are convenient for this project
pub const helpers = struct {
    const vk = @import("vulkan");

    // RGB image stored in memory as RGBA buffer
    pub const Rgba2D = struct {
        ptr: [*][4]f32,
        extent: vk.Extent2D,

        pub fn asSlice(self: Rgba2D) [][4]f32 {
            var slice: [][4]f32 = undefined;
            slice.ptr = self.ptr;
            slice.len = self.extent.width * self.extent.height;
            return slice;
        }

        pub fn save(self: Rgba2D, allocator: std.mem.Allocator, out_filename: []const u8) !void {
            const channel_count = 3;

            var header: Header = undefined;
            initExrHeader(&header);

            var image: Image = undefined;
            initExrImage(&image);

            const pixel_count = self.extent.width * self.extent.height;

            const ImageChannels = std.MultiArrayList(struct {
                r: f32,
                g: f32,
                b: f32,
            });
            var image_channels = ImageChannels {};
            defer image_channels.deinit(allocator);

            try image_channels.ensureUnusedCapacity(allocator, pixel_count);

            for (0..pixel_count) |i| {
                image_channels.appendAssumeCapacity(.{
                    .r = self.asSlice()[i][0],
                    .g = self.asSlice()[i][1],
                    .b = self.asSlice()[i][2],
                });
            }

            const image_channels_slice = image_channels.slice();
            image.num_channels = channel_count;
            image.images = @constCast(&[3][*c]u8 {
                image_channels_slice.ptrs[2],
                image_channels_slice.ptrs[1],
                image_channels_slice.ptrs[0],
            });
            image.width = @intCast(self.extent.width);
            image.height = @intCast(self.extent.height);

            const header_channels = try allocator.alloc(ChannelInfo, channel_count);
            defer allocator.free(header_channels);

            const pixel_types = try allocator.alloc(c_int, channel_count);
            defer allocator.free(pixel_types);
            const requested_pixel_types = try allocator.alloc(c_int, channel_count);
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

            inline for (0..channel_count) |i| {
                header.pixel_types[i] = @intFromEnum(PixelType.float);
                header.requested_pixel_types[i] = @intFromEnum(PixelType.float);
            }

            var data: [*c]u8 = undefined;
            const file_size = try saveEXRImageToMemory(&image, &header, &data);
            try std.fs.cwd().writeFile(out_filename, data[0..file_size]);
            std.heap.c_allocator.free(data[0..file_size]);
        }

        pub fn load(allocator: std.mem.Allocator, filename: []const u8) !Rgba2D {
            const file_content = try std.fs.cwd().readFileAlloc(allocator, filename, std.math.maxInt(usize));
            defer allocator.free(file_content);

            var out_rgba: [*c]f32 = undefined;
            var width: c_int = undefined;
            var height: c_int = undefined;
            try loadEXRFromMemory(&out_rgba, &width, &height, file_content.ptr, file_content.len);
            const malloc_slice = Rgba2D {
                .ptr = @ptrCast(out_rgba),
                .extent = vk.Extent2D {
                    .width = @intCast(width),
                    .height = @intCast(height),
                },
            };
            const out = Rgba2D {
                .ptr = (try allocator.dupe([4]f32, malloc_slice.asSlice())).ptr, // copy into zig allocator
                .extent = malloc_slice.extent,
            };
            std.heap.c_allocator.free(malloc_slice.asSlice());
            return out;
        }
    };
};
