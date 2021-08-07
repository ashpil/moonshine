const std = @import("std");
const zug = @import("./zug.zig");

const u32x3 = zug.Vec3(u32);
const f32x3 = zug.Vec3(f32);

vertices: []f32x3,
indices: []u32x3,

const Self = @This();

const Error = error {
    MissingPosition,
    MissingIndex,
};

const Sizes = struct {
    num_vertices: u32,
    num_indices: u32,
};

pub fn getObjSizes(contents: []const u8) Sizes {
    var lines = std.mem.tokenize(contents, "\n");

    var num_vertices: u32 = 0;
    var num_indices: u32 = 0;
    while (lines.next()) |line| {
        const line_type = categorizeLine(line[0]);
        switch (line_type) {
            .position => num_vertices += 1,
            .index => num_indices += 1,
            else => {},
        }
    }

    return Sizes {
        .num_vertices = num_vertices,
        .num_indices = num_indices,
    };
}

pub fn fromObj(allocator: *std.mem.Allocator, contents: []const u8) !Self {
    const sizes = getObjSizes(contents);
    const vertices = try allocator.alloc(f32x3, sizes.num_vertices);
    const indices = try allocator.alloc(u32x3, sizes.num_indices);

    var lines = std.mem.tokenize(contents, "\n");
    var current_position: u32 = 0;
    var current_index: u32 = 0;
    while (lines.next()) |line| {
        const line_type = categorizeLine(line[0]);
        if (line_type == .comment) continue;
        var iter = std.mem.tokenize(line[1..], " ");
        switch (line_type) {
            .position => { 
                vertices[current_position] = try vertexFromIter(&iter);
                current_position += 1;
            },
            .index => { 
                indices[current_index] = try indexFromIter(&iter);
                current_index += 1;
            },
            else => unreachable, // TODO
        }
    }

    return Self {
        .vertices = vertices,
        .indices = indices,
    };
}

pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
    allocator.free(self.vertices);
    allocator.free(self.indices);
}

const LineType = enum {
    comment,
    position,
    index,
};

fn categorizeLine(first_char: u8) LineType {
    return switch (first_char) {
        '#' => .comment,
        'v' => .position,
        'f' => .index,
        else => unreachable, // TODO if we want more
    };
}

fn vertexFromIter(iter: *std.mem.TokenIterator) !f32x3 {
    const x = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingPosition;
    const y = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingPosition;
    const z = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingPosition;
    return f32x3.new(x, y, z);
}

fn indexFromIter(iter: *std.mem.TokenIterator) !u32x3 {
    const x = if (iter.next()) |val| try std.fmt.parseInt(u32, val, 10) else return Error.MissingIndex;
    const y = if (iter.next()) |val| try std.fmt.parseInt(u32, val, 10) else return Error.MissingIndex;
    const z = if (iter.next()) |val| try std.fmt.parseInt(u32, val, 10) else return Error.MissingIndex;
    return u32x3.new(x - 1, y - 1, z - 1);
}

