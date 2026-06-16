const c = @import("tinyexr");
const std = @import("std");

pub const TinyExrError = error {
    InvalidArgument,
    InvalidFile,
    UnsupportedFeature,
    OutOfMemory,
    Io,
    Corrupt,
    InvalidData,
};

const Image = c.exr_image;
const Part = c.exr_part;

fn check(result: c.exr_result) TinyExrError!void {
    return switch (result) {
        c.EXR_SUCCESS => {},
        c.EXR_ERROR_INVALID_ARGUMENT => TinyExrError.InvalidArgument,
        c.EXR_ERROR_INVALID_FILE => TinyExrError.InvalidFile,
        c.EXR_ERROR_UNSUPPORTED => TinyExrError.UnsupportedFeature,
        c.EXR_ERROR_OUT_OF_MEMORY => TinyExrError.OutOfMemory,
        c.EXR_ERROR_IO => TinyExrError.Io,
        c.EXR_ERROR_CORRUPT => TinyExrError.Corrupt,
        else => TinyExrError.InvalidData,
    };
}

// Routes tinyexr's internal allocations through a std.mem.Allocator. The C free
// callback gets no size, so we over-allocate and stash the total length in a
// 16-byte header before the returned pointer (which keeps the payload 16-byte
// aligned for tinyexr's SIMD codecs).
fn exr_allocator(allocator: *const std.mem.Allocator) c.exr_allocator {
    const Inner = struct {
        const alignment = std.mem.Alignment.fromByteUnits(16);
        const header = alignment.toByteUnits();

        fn alloc(user: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
            const a: *const std.mem.Allocator = @ptrCast(@alignCast(user.?));
            const total = header + size;
            const raw = a.rawAlloc(total, alignment, @returnAddress()) orelse return null;
            @as(*usize, @ptrCast(@alignCast(raw))).* = total;
            return @ptrCast(raw + header);
        }

        fn free(user: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
            const payload = ptr orelse return;
            const a: *const std.mem.Allocator = @ptrCast(@alignCast(user.?));
            const raw = @as([*]u8, @ptrCast(payload)) - header;
            const total = @as(*const usize, @ptrCast(@alignCast(raw))).*;
            a.rawFree(raw[0..total], alignment, @returnAddress());
        }
    };
    return .{ .user = @ptrCast(@constCast(allocator)), .alloc = &Inner.alloc, .free = &Inner.free };
}

pub const helpers = struct {
    const vk = @import("vulkan");

    pub const Rgba2D = struct {
        ptr: [*][4]f32,
        extent: vk.Extent2D,

        pub fn asSlice(self: Rgba2D) [][4]f32 {
            var slice: [][4]f32 = undefined;
            slice.ptr = self.ptr;
            slice.len = self.extent.width * self.extent.height;
            return slice;
        }

        pub fn save(self: Rgba2D, allocator: std.mem.Allocator, io: std.Io, filepath: []const u8) !void {
            const channel_count = 3;
            const pixel_count = self.extent.width * self.extent.height;

            const b_plane = try allocator.alloc(f32, pixel_count);
            defer allocator.free(b_plane);
            const g_plane = try allocator.alloc(f32, pixel_count);
            defer allocator.free(g_plane);
            const r_plane = try allocator.alloc(f32, pixel_count);
            defer allocator.free(r_plane);
            for (self.asSlice(), 0..) |pixel, i| {
                r_plane[i] = pixel[0];
                g_plane[i] = pixel[1];
                b_plane[i] = pixel[2];
            }

            const name_pad = [_]u8{0} ** (c.EXR_MAX_NAME - 1);
            var channels = [channel_count]c.exr_channel {
                .{ .name = [_]u8{'B'} ++ name_pad, .pixel_type = c.EXR_PIXEL_FLOAT, .x_sampling = 1, .y_sampling = 1, .p_linear = 0 },
                .{ .name = [_]u8{'G'} ++ name_pad, .pixel_type = c.EXR_PIXEL_FLOAT, .x_sampling = 1, .y_sampling = 1, .p_linear = 0 },
                .{ .name = [_]u8{'R'} ++ name_pad, .pixel_type = c.EXR_PIXEL_FLOAT, .x_sampling = 1, .y_sampling = 1, .p_linear = 0 },
            };

            var images = [channel_count]?*anyopaque {
                @ptrCast(b_plane.ptr),
                @ptrCast(g_plane.ptr),
                @ptrCast(r_plane.ptr),
            };

            const data_window = c.exr_box2i {
                .min_x = 0,
                .min_y = 0,
                .max_x = @intCast(self.extent.width - 1),
                .max_y = @intCast(self.extent.height - 1),
            };
            var part = Part {
                .header = .{
                    .part_type = c.EXR_PART_SCANLINE,
                    .compression = c.EXR_COMPRESSION_NONE,
                    .line_order = c.EXR_LINEORDER_INCREASING_Y,
                    .data_window = data_window,
                    .display_window = data_window,
                    .pixel_aspect_ratio = 1.0,
                    .screen_window_center_x = 0.0,
                    .screen_window_center_y = 0.0,
                    .screen_window_width = 1.0,
                    .num_channels = channel_count,
                    .channels = &channels,
                    .tiled = 0,
                    .tile_x_size = 0,
                    .tile_y_size = 0,
                    .level_mode = c.EXR_TILE_ONE_LEVEL,
                    .rounding_mode = c.EXR_TILE_ROUND_DOWN,
                    .name = @splat(0),
                    .attrs = null,
                },
                .width = @intCast(self.extent.width),
                .height = @intCast(self.extent.height),
                .images = &images,
                .is_deep = 0,
                .deep_sample_counts = null,
                .deep_images = null,
                .deep_total_samples = 0,
            };

            const alloc = exr_allocator(&allocator);
            var image = Image {
                .num_parts = 1,
                .parts = &part,
                .alloc = alloc,
            };
            var data: ?*anyopaque = null;
            var out_size: usize = 0;
            try check(c.exr_save_to_memory(&data, &out_size, &alloc, &image, std.math.maxInt(c_uint)));
            defer alloc.free.?(alloc.user, data);

            const bytes: [*]const u8 = @ptrCast(data.?);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filepath, .data = bytes[0..out_size] });
        }

        pub fn load(allocator: std.mem.Allocator, io: std.Io, filepath: []const u8) !Rgba2D {
            const file_content = try std.Io.Dir.cwd().readFileAlloc(io, filepath, allocator, .unlimited);
            defer allocator.free(file_content);

            const alloc = exr_allocator(&allocator);
            var image: Image = undefined;
            try check(c.exr_load_from_memory(file_content.ptr, file_content.len, &alloc, &image));
            defer c.exr_image_free(&image);

            if (image.num_parts < 1 or image.parts == null) return TinyExrError.InvalidData;
            const part: *const Part = @ptrCast(&image.parts[0]);
            if (part.is_deep != 0 or part.images == null) return TinyExrError.UnsupportedFeature;

            const width: u32 = @intCast(part.width);
            const height: u32 = @intCast(part.height);
            const pixel_count: usize = @as(usize, width) * height;

            const out = try allocator.alloc([4]f32, pixel_count);
            errdefer allocator.free(out);

            const channels: [*]const c.exr_channel = @ptrCast(part.header.channels);
            var indices = [4]?usize { null, null, null, null }; // R, G, B, A
            for (0..@intCast(part.header.num_channels)) |i| {
                const name = std.mem.sliceTo(&channels[i].name, 0);
                if (std.mem.eql(u8, name, "R")) {
                    indices[0] = i;
                } else if (std.mem.eql(u8, name, "G")) {
                    indices[1] = i;
                } else if (std.mem.eql(u8, name, "B")) {
                    indices[2] = i;
                } else if (std.mem.eql(u8, name, "A")) {
                    indices[3] = i;
                }
            }

            for (indices, 0..) |maybe_index, component| {
                const index = maybe_index orelse {
                    const default: f32 = if (component == 3) 1.0 else 0.0; // missing alpha -> opaque
                    for (out) |*pixel| pixel[component] = default;
                    continue;
                };
                const plane = part.images[index].?;
                switch (part.header.channels[index].pixel_type) {
                    c.EXR_PIXEL_HALF => {
                        const halfs: [*]const f16 = @ptrCast(@alignCast(plane));
                        for (out, 0..) |*pixel, i| pixel[component] = @floatCast(halfs[i]);
                    },
                    c.EXR_PIXEL_FLOAT => {
                        const floats: [*]const f32 = @ptrCast(@alignCast(plane));
                        for (out, 0..) |*pixel, i| pixel[component] = floats[i];
                    },
                    c.EXR_PIXEL_UINT => {
                        const uints: [*]const u32 = @ptrCast(@alignCast(plane));
                        for (out, 0..) |*pixel, i| pixel[component] = @floatFromInt(uints[i]);
                    },
                    else => {},
                }
            }

            return Rgba2D {
                .ptr = out.ptr,
                .extent = .{ .width = width, .height = height },
            };
        }
    };
};
