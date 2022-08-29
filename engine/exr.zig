const c = @import("./c.zig");
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

