const std = @import("std");
const zug = @import("./zug.zig");

const u32x3 = zug.Vec3(u32);
const f32x3 = zug.Vec3(f32);
const f32x2 = zug.Vec2(f32);

const Vertex = struct {
    position: f32x3,
    texture: f32x2,
};

vertices: []Vertex,
indices: []u32x3,

const Self = @This();

const Error = error {
    MissingPosition,
    MissingTexture,
    MissingIndex,
};

const Sizes = struct {
    num_positions: u32,
    num_textures: u32,
    num_indices: u32,
};

pub fn getObjSizes(contents: []const u8) Sizes {
    var lines = std.mem.tokenize(u8, contents, "\n");

    var num_positions: u32 = 0;
    var num_textures: u32 = 0;
    var num_indices: u32 = 0;
    while (lines.next()) |line| {
        var iter = std.mem.tokenize(u8, line, " ");
        const line_type = categorizeLine(iter.next().?);
        switch (line_type) {
            .position => num_positions += 1,
            .texture => num_textures += 1,
            .index => num_indices += 1,
            else => {},
        }
    }

    return Sizes {
        .num_positions = num_positions,
        .num_textures = num_textures,
        .num_indices = num_indices,
    };
}

pub fn fromObj(allocator: *std.mem.Allocator, contents: []const u8) !Self {
    const sizes = getObjSizes(contents);
    const positions = try allocator.alloc(f32x3, sizes.num_positions);
    defer allocator.free(positions);
    const textures = try allocator.alloc(f32x2, sizes.num_textures);
    defer allocator.free(textures);
    const indices = try allocator.alloc(u32x3, sizes.num_indices);
    var vertices = try allocator.alloc(Vertex, sizes.num_indices * 3);

    var lines = std.mem.tokenize(u8, contents, "\n");
    var current_position: u32 = 0;
    var current_texture: u32 = 0;
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
            .texture => { 
                textures[current_texture] = try textureFromIter(&iter);
                current_texture += 1;
            },
            .index => {
                var i: u32 = 0;
                var index = u32x3.new(0, 0, 0);
                while (i < 3) : (i += 1) {
                    const index_str = iter.next() orelse return Error.MissingIndex;
                    var numbers = std.mem.tokenize(u8, index_str, "/");
                    const position_index = if (numbers.next()) |val| ((try std.fmt.parseInt(u32, val, 10)) - 1) else return Error.MissingIndex;
                    const texture_index = if (numbers.next()) |val| ((try std.fmt.parseInt(u32, val, 10)) - 1) else return Error.MissingIndex;
                    const vertex = Vertex {
                        .position = positions[position_index],
                        .texture = textures[texture_index],
                    };
                    var j: u32 = 0;
                    while (j < current_vertex) : (j += 1) {
                        if (std.meta.eql(vertex, vertices[j])) {
                            switch (i) {
                                0 => index.x = j,
                                1 => index.y = j,
                                2 => index.z = j,
                                else => unreachable,
                            }
                            break;
                        }
                    } else {
                        switch (i) {
                            0 => index.x = current_vertex,
                            1 => index.y = current_vertex,
                            2 => index.z = current_vertex,
                            else => unreachable,
                        }
                        vertices[current_vertex] = vertex;
                        current_vertex += 1;     
                    }
                }
                indices[current_index] = index;
                current_index += 1;
            }
        }
    }

    vertices = try allocator.realloc(vertices, current_vertex);

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
    texture,
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
        return .texture;
    } else unreachable; // TODO if we want more
}

fn textureFromIter(iter: *std.mem.TokenIterator(u8)) !f32x2 {
    const x = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingTexture;
    const y = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingTexture;
    return f32x2.new(x, y);
}

fn positionFromIter(iter: *std.mem.TokenIterator(u8)) !f32x3 {
    const x = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingPosition;
    const y = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingPosition;
    const z = if (iter.next()) |val| try std.fmt.parseFloat(f32, val) else return Error.MissingPosition;
    return f32x3.new(x, y, z);
}

fn indexFromIter(iter: *std.mem.TokenIterator(u8)) !u32x3 {
    const x = if (iter.next()) |val| try std.fmt.parseInt(u32, val, 10) else return Error.MissingIndex;
    const y = if (iter.next()) |val| try std.fmt.parseInt(u32, val, 10) else return Error.MissingIndex;
    const z = if (iter.next()) |val| try std.fmt.parseInt(u32, val, 10) else return Error.MissingIndex;
    return u32x3.new(x - 1, y - 1, z - 1);
}

