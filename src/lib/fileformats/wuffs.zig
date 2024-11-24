const c = @import("../c.zig");
const std = @import("std");

fn ToWuffsSliceType(comptime T: type) type {
    return switch (T) {
        u8 => c.wuffs_base__slice_u8,
        u16 => c.wuffs_base__slice_u16,
        u32 => c.wuffs_base__slice_u32,
        u64 => c.wuffs_base__slice_u64,
        else => @compileError(@typeName(T) ++ " is not a valid wuffs slice type"),
    };
}

fn toWuffsSlice(comptime T: type, slice: []T) ToWuffsSliceType(T) {
    const f = switch (T) {
        u8 => c.wuffs_base__make_slice_u8,
        u16 => c.wuffs_base__make_slice_u16,
        u32 => c.wuffs_base__make_slice_u32,
        u64 => c.wuffs_base__make_slice_u64,
        else => @compileError(@typeName(T) ++ " is not a valid wuffs slice type"),
    };
    return f(slice.ptr, slice.len);
}

fn statusToError(status: c.wuffs_base__status) !void {
    // TODO: make this actually useful
    if (!c.wuffs_base__status__is_ok(&status)) return error.WuffsError;
}

const FourCC = enum(u32) {
    unknown = 0,
    abxr = c.WUFFS_BASE__FOURCC__ABXR,
    abxs = c.WUFFS_BASE__FOURCC__ABXS,
    bgcl = c.WUFFS_BASE__FOURCC__BGCL,
    bmp = c.WUFFS_BASE__FOURCC__BMP,
    brtl = c.WUFFS_BASE__FOURCC__BRTL,
    bz2 = c.WUFFS_BASE__FOURCC__BZ2,
    cbor = c.WUFFS_BASE__FOURCC__CBOR,
    chrm = c.WUFFS_BASE__FOURCC__CHRM,
    css = c.WUFFS_BASE__FOURCC__CSS,
    eps = c.WUFFS_BASE__FOURCC__EPS,
    etc2 = c.WUFFS_BASE__FOURCC__ETC2,
    exif = c.WUFFS_BASE__FOURCC__EXIF,
    flac = c.WUFFS_BASE__FOURCC__FLAC,
    gama = c.WUFFS_BASE__FOURCC__GAMA,
    gif = c.WUFFS_BASE__FOURCC__GIF,
    gz = c.WUFFS_BASE__FOURCC__GZ,
    heif = c.WUFFS_BASE__FOURCC__HEIF,
    html = c.WUFFS_BASE__FOURCC__HTML,
    iccp = c.WUFFS_BASE__FOURCC__ICCP,
    ico = c.WUFFS_BASE__FOURCC__ICO,
    icvg = c.WUFFS_BASE__FOURCC__ICVG,
    ini = c.WUFFS_BASE__FOURCC__INI,
    jpeg = c.WUFFS_BASE__FOURCC__JPEG,
    js = c.WUFFS_BASE__FOURCC__JS,
    json = c.WUFFS_BASE__FOURCC__JSON,
    jwcc = c.WUFFS_BASE__FOURCC__JWCC,
    kvp = c.WUFFS_BASE__FOURCC__KVP,
    kvpk = c.WUFFS_BASE__FOURCC__KVPK,
    kvpv = c.WUFFS_BASE__FOURCC__KVPV,
    lz4 = c.WUFFS_BASE__FOURCC__LZ4,
    lzip = c.WUFFS_BASE__FOURCC__LZIP,
    lzma = c.WUFFS_BASE__FOURCC__LZMA,
    md = c.WUFFS_BASE__FOURCC__MD,
    mtim = c.WUFFS_BASE__FOURCC__MTIM,
    mp3 = c.WUFFS_BASE__FOURCC__MP3,
    nie = c.WUFFS_BASE__FOURCC__NIE,
    npbm = c.WUFFS_BASE__FOURCC__NPBM,
    ofs2 = c.WUFFS_BASE__FOURCC__OFS2,
    otf = c.WUFFS_BASE__FOURCC__OTF,
    pdf = c.WUFFS_BASE__FOURCC__PDF,
    phyd = c.WUFFS_BASE__FOURCC__PHYD,
    png = c.WUFFS_BASE__FOURCC__PNG,
    ps = c.WUFFS_BASE__FOURCC__PS,
    qoi = c.WUFFS_BASE__FOURCC__QOI,
    rac = c.WUFFS_BASE__FOURCC__RAC,
    raw = c.WUFFS_BASE__FOURCC__RAW,
    riff = c.WUFFS_BASE__FOURCC__RIFF,
    rigl = c.WUFFS_BASE__FOURCC__RIGL,
    snpy = c.WUFFS_BASE__FOURCC__SNPY,
    srgb = c.WUFFS_BASE__FOURCC__SRGB,
    svg = c.WUFFS_BASE__FOURCC__SVG,
    tar = c.WUFFS_BASE__FOURCC__TAR,
    text = c.WUFFS_BASE__FOURCC__TEXT,
    tga = c.WUFFS_BASE__FOURCC__TGA,
    th = c.WUFFS_BASE__FOURCC__TH,
    tiff = c.WUFFS_BASE__FOURCC__TIFF,
    toml = c.WUFFS_BASE__FOURCC__TOML,
    wave = c.WUFFS_BASE__FOURCC__WAVE,
    wbmp = c.WUFFS_BASE__FOURCC__WBMP,
    webp = c.WUFFS_BASE__FOURCC__WEBP,
    woff = c.WUFFS_BASE__FOURCC__WOFF,
    xml = c.WUFFS_BASE__FOURCC__XML,
    xmp = c.WUFFS_BASE__FOURCC__XMP,
    xz = c.WUFFS_BASE__FOURCC__XZ,
    zip = c.WUFFS_BASE__FOURCC__ZIP,
    zlib = c.WUFFS_BASE__FOURCC__ZLIB,
    zstd = c.WUFFS_BASE__FOURCC__ZSTD,

    fn toDecodableImageFileFormat(self: FourCC) ?DecodableImageFileFormat {
        return switch (self) {
            .bmp => .bmp,
            .etc2 => .etc2,
            .gif => .gif,
            .jpeg => .jpeg,
            .nie => .nie,
            .npbm => .netpbm,
            .png => .png,
            .qoi => .qoi,
            .tga => .targa,
            .th => .thumbhash,
            .wbmp => .wbmp,
            .webp => .webp,
            else => null,
        };
    }
};

const DecodableImageFileFormat = enum {
    bmp,
    etc2,
    gif,
    jpeg,
    nie,
    netpbm,
    png,
    qoi,
    targa,
    thumbhash,
    wbmp,
    webp,
};

fn guessFourCC(slice: []const u8) !FourCC {
    const res = c.wuffs_base__magic_number_guess_fourcc(toWuffsSlice(u8, @constCast(slice)), true);
    if (res == -1) return error.Incomplete else return @enumFromInt(res);
}

fn createDecoder(format: DecodableImageFileFormat, allocator: std.mem.Allocator) !*c.wuffs_base__image_decoder {
    inline for (comptime std.meta.tags(DecodableImageFileFormat)) |tag| {
        if (tag == format) {
            const size = @field(c, "sizeof__wuffs_" ++  @tagName(tag) ++ "__decoder")();
            const slice = try allocator.alloc(u8, size);
            errdefer allocator.free(slice);

            try statusToError(@field(c, "wuffs_" ++  @tagName(tag) ++ "__decoder__initialize")(@ptrCast(slice), size, c.WUFFS_VERSION, c.WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED));

            return @field(c, "wuffs_" ++  @tagName(tag) ++ "__decoder__upcast_as__wuffs_base__image_decoder")(@ptrCast(slice)).?;
        }
    } else unreachable;
}

fn destroyDecoder(format: DecodableImageFileFormat, allocator: std.mem.Allocator, decoder: *const c.wuffs_base__image_decoder) void {
    inline for (comptime std.meta.tags(DecodableImageFileFormat)) |tag| {
        if (tag == format) {
            const bytes: [*]const u8 = @ptrCast(decoder);
            const size = @field(c, "sizeof__wuffs_" ++  @tagName(tag) ++ "__decoder")();
            const slice = bytes[0..size];
            allocator.free(slice);
            return;
        }
    } else unreachable;
}

pub fn load(allocator: std.mem.Allocator, buffer: []const u8) !std.meta.Tuple(&.{[]const u8, u32, u32}) {
    var src = c.wuffs_base__ptr_u8__reader(@constCast(buffer.ptr), buffer.len, true);
    const format = (try guessFourCC(buffer)).toDecodableImageFileFormat() orelse return error.NotImage;

    const decoder = try createDecoder(format, allocator);
    defer destroyDecoder(format, allocator, decoder);

    var ic: c.wuffs_base__image_config = undefined;
    try statusToError(c.wuffs_base__image_decoder__decode_image_config(decoder, &ic, &src));

    const width = c.wuffs_base__pixel_config__width(&ic.pixcfg);
    const height = c.wuffs_base__pixel_config__height(&ic.pixcfg);

    var pc: c.wuffs_base__pixel_config = undefined;
    c.wuffs_base__pixel_config__set(&pc, c.WUFFS_BASE__PIXEL_FORMAT__RGB, c.WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, width, height);

    const work_buffer = try allocator.alloc(u8, c.wuffs_base__image_decoder__workbuf_len(decoder).max_incl);
    defer allocator.free(work_buffer);

    const pixel_buffer = try allocator.alloc(u8, width * height * 3);

    var pb: c.wuffs_base__pixel_buffer = undefined;
    try statusToError(c.wuffs_base__pixel_buffer__set_from_slice(&pb, &pc, toWuffsSlice(u8, pixel_buffer)));

    try statusToError(c.wuffs_base__image_decoder__decode_frame(decoder, &pb, &src, c.WUFFS_BASE__PIXEL_BLEND__SRC, toWuffsSlice(u8, work_buffer), null));

    return .{ pixel_buffer, width, height };
}