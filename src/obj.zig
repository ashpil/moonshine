const std = @import("std");
const zug = @import("./zug.zig");

const u32x3 = zug.Vec3(u32);
const f32x3 = zug.Vec3(f32);

positions: []f32x3,
indices: []u32x3,

const Self = @This();

const Error = error {
    MissingPosition,
    MissingIndex,
};

const Sizes = struct {
    num_positions: u32,
    num_indices: u32,
};

pub fn getSizes(contents: []const u8) Sizes {
    var lines = std.mem.tokenize(contents, "\n");

    var num_positions: u32 = 0;
    var num_indices: u32 = 0;
    @setEvalBranchQuota(10000);
    while (lines.next()) |line| {
        const line_type = categorizeLine(line[0]);
        switch (line_type) {
            .position => num_positions += 1,
            .index => num_indices += 1,
            else => {},
        }
    }

    return Sizes {
        .num_positions = num_positions,
        .num_indices = num_indices,
    };
}

pub fn GetReturn(comptime contents: []const u8) type {
    const sizes = comptime getSizes(contents);

    return struct {
        positions: [sizes.num_positions]f32x3,
        indices: [sizes.num_indices]u32x3,
    };
}

pub fn parse(comptime contents: []const u8) !GetReturn(contents) {
    const ReturnType = GetReturn(contents);

    var result: ReturnType = undefined;

    var lines = std.mem.tokenize(contents, "\n");
    var current_position: u32 = 0;
    var current_index: u32 = 0;
    while (lines.next()) |line| {
        const line_type = categorizeLine(line[0]);
        if (line_type == .comment) continue;
        var iter = std.mem.tokenize(line[1..], " ");
        switch (line_type) {
            .position => { 
                result.positions[current_position] = try vertexFromIter(&iter);
                current_position += 1;
            },
            .index => { 
                result.indices[current_index] = try indexFromIter(&iter);
                current_index += 1;
            },
            else => unreachable, // TODO
        }
    }

    return result;
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
    return u32x3.new(x, y, z);
}

