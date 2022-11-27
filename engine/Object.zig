// Stores vertex data, ready to be loaded into system
// TODO: make this obsolete, load immediately from disk to GPU memory

const std = @import("std");
const vector = @import("./vector.zig");

const U32x3 = vector.Vec3(u32);
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);

// vertices
positions: []F32x3, // required
texcoords: ?[]F32x2, // optional
normals: ?[]F32x3, // optional

// indices
indices: []U32x3,

const Self = @This();

const Error = error {
    MissingPosition,
    MissingTexture,
    MissingIndex,
};

const Sizes = struct {
    num_positions: u32,
    num_texcoords: u32,
    num_indices: u32,
};

pub fn getObjSizes(contents: []const u8) Sizes {
    var lines = std.mem.tokenize(u8, contents, "\n");

    var num_positions: u32 = 0;
    var num_texcoords: u32 = 0;
    var num_indices: u32 = 0;
    while (lines.next()) |line| {
        var iter = std.mem.tokenize(u8, line, " ");
        const line_type = categorizeLine(iter.next().?);
        switch (line_type) {
            .position => num_positions += 1,
            .texcoord => num_texcoords += 1,
            .index => num_indices += 1,
            else => {},
        }
    }

    return Sizes {
        .num_positions = num_positions,
        .num_texcoords = num_texcoords,
        .num_indices = num_indices,
    };
}

// THIS REALLY NEEDS TO BE REMOVED -- make own mesh serialization
//
// not super efficient as the idea is that this won't be used all that much
// since obj is a stupid format anyway
// by not efficient, this means it doesn't do vertex deduplication, which is quite crucial for obj files
// it loads stuff relatively efficiently, but the stuff it loads may not be efficient
//
// TODO: load vertex normals when available
pub fn fromObj(allocator: std.mem.Allocator, file: std.fs.File) !Self {
    var buffered_reader = std.io.bufferedReader(file.reader());
    const reader = buffered_reader.reader();
    const contents = try reader.readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    const sizes = getObjSizes(contents);
    const positions = try allocator.alloc(F32x3, sizes.num_positions);
    defer allocator.free(positions);
    const texcoords = try allocator.alloc(F32x2, sizes.num_texcoords);
    defer allocator.free(texcoords);
    const indices = try allocator.alloc(U32x3, sizes.num_indices);

    var final_positions = std.ArrayList(F32x3).init(allocator);
    var final_texcoords = std.ArrayList(F32x2).init(allocator);

    var lines = std.mem.tokenize(u8, contents, "\n");
    var current_position: u32 = 0;
    var current_texcoord: u32 = 0;
    var current_index: u32 = 0;
    var current_vertex: u32 = 0;
    while (lines.next()) |line| {
        var iter = std.mem.tokenize(u8, line, " ");
        const line_type = categorizeLine(iter.next().?);
        switch (line_type) {
            .comment => continue,
            .position => { 
                positions[current_position] = try positionFromIter(&iter);
                current_position += 1;
            },
            .texcoord => { 
                texcoords[current_texcoord] = try texcoordFromIter(&iter);
                current_texcoord += 1;
            },
            .index => {
                var i: u32 = 0;
                var index = U32x3.new(0, 0, 0);
                while (i < 3) : (i += 1) {
                    const index_str = iter.next() orelse return Error.MissingIndex;
                    var numbers = std.mem.tokenize(u8, index_str, "/");
                    const position_index = if (numbers.next()) |val| ((try std.fmt.parseInt(u32, val, 10)) - 1) else return Error.MissingIndex;
                    const texcoord_index = if (numbers.next()) |val| ((try std.fmt.parseInt(u32, val, 10)) - 1) else return Error.MissingIndex;
                    try final_positions.append(positions[position_index]);
                    try final_texcoords.append(texcoords[texcoord_index]);
                    switch (i) {
                        0 => index.x = current_vertex,
                        1 => index.y = current_vertex,
                        2 => index.z = current_vertex,
                        else => unreachable,
                    }
                    current_vertex += 1;
                }
                indices[current_index] = index;
                current_index += 1;
            }
        }
    }

    std.debug.assert(final_positions.items.len == final_texcoords.items.len);
    
    return Self {
        .positions = final_positions.toOwnedSlice(),
        .texcoords = final_texcoords.toOwnedSlice(),
        .normals = null,
        .indices = indices,
    };
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.positions);
    if (self.texcoords) |texcoords| allocator.free(texcoords);
    if (self.normals) |normals| allocator.free(normals);
    allocator.free(self.indices);
}

const LineType = enum {
    comment,
    position,
    texcoord,
    index,
};

fn categorizeLine(first_token: []const u8) LineType {
    if (std.mem.eql(u8, first_token, "#")) {
        return .comment;
    } else if (std.mem.eql(u8, first_token, "v")) {
        return .position;
    } else if (std.mem.eql(u8, first_token, "f")) {
        return .index;
    } else if (std.mem.eql(u8, first_token, "vt")) {
        return .texcoord;
    } else {
        std.debug.print("Unknown line: {s}\n", .{first_token});
        unreachable;
    }
}

fn texcoordFromIter(iter: *std.mem.TokenIterator(u8)) !F32x2 {
    const x = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingTexture;
    const y = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingTexture;
    return F32x2.new(x, y);
}

fn positionFromIter(iter: *std.mem.TokenIterator(u8)) !F32x3 {
    const x = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingPosition;
    const y = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingPosition;
    const z = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingPosition;
    return F32x3.new(x, y, z);
}

fn indexFromIter(iter: *std.mem.TokenIterator(u8)) !U32x3 {
    const x = if (iter.next()) |val| try std.fmt.parseInt(u32, val, 10) else return Error.MissingIndex;
    const y = if (iter.next()) |val| try std.fmt.parseInt(u32, val, 10) else return Error.MissingIndex;
    const z = if (iter.next()) |val| try std.fmt.parseInt(u32, val, 10) else return Error.MissingIndex;
    return U32x3.new(x - 1, y - 1, z - 1);
}

