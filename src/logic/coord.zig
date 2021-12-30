const zug = @import("../utils/zug.zig");
const Mat3x4 = zug.Mat3x4(f32);
const F32x3 = zug.Vec3(f32);
const F32x2 = zug.Vec2(f32);

// this could theoretically be deduplicated but I think it provides the most
// conceptually simple interface
pub const Coord = enum {
    a1,
    a2,
    a3,
    a4,
    a5,
    a6,
    a7,
    a8,
    b1,
    b2,
    b3,
    b4,
    b5,
    b6,
    b7,
    b8,
    c1,
    c2,
    c3,
    c4,
    c5,
    c6,
    c7,
    c8,
    d1,
    d2,
    d3,
    d4,
    d5,
    d6,
    d7,
    d8,
    e1,
    e2,
    e3,
    e4,
    e5,
    e6,
    e7,
    e8,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    g1,
    g2,
    g3,
    g4,
    g5,
    g6,
    g7,
    g8,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    h7,
    h8,

    pub const board_size = 0.5;

    const half_tile_size = board_size / 16.0;

    const a = half_tile_size * 7.0;
    const b = half_tile_size * 5.0;
    const c = half_tile_size * 3.0;
    const d = half_tile_size * 1.0;
    const e = half_tile_size * -1.0;
    const f = half_tile_size * -3.0;
    const g = half_tile_size * -5.0;
    const h = half_tile_size * -7.0;

    const @"1" = half_tile_size * -7.0;
    const @"2" = half_tile_size * -5.0;
    const @"3" = half_tile_size * -3.0;
    const @"4" = half_tile_size * -1.0;
    const @"5" = half_tile_size * 1.0;
    const @"6" = half_tile_size * 3.0;
    const @"7" = half_tile_size * 5.0;
    const @"8" = half_tile_size * 7.0;

    pub fn fromLocation(location: F32x2) Coord {
        if (location.x < @"1" + half_tile_size) {
            if (location.y > a - half_tile_size) return .a1
            else if (location.y > b - half_tile_size) return .b1
            else if (location.y > c - half_tile_size) return .c1
            else if (location.y > d - half_tile_size) return .d1
            else if (location.y > e - half_tile_size) return .e1
            else if (location.y > f - half_tile_size) return .f1
            else if (location.y > g - half_tile_size) return .g1
            else return .h1;
        } else if (location.x < @"2" + half_tile_size) {
            if (location.y > a - half_tile_size) return .a2
            else if (location.y > b - half_tile_size) return .b2
            else if (location.y > c - half_tile_size) return .c2
            else if (location.y > d - half_tile_size) return .d2
            else if (location.y > e - half_tile_size) return .e2
            else if (location.y > f - half_tile_size) return .f2
            else if (location.y > g - half_tile_size) return .g2
            else return .h2;
        } else if (location.x < @"3" + half_tile_size) {
            if (location.y > a - half_tile_size) return .a3
            else if (location.y > b - half_tile_size) return .b3
            else if (location.y > c - half_tile_size) return .c3
            else if (location.y > d - half_tile_size) return .d3
            else if (location.y > e - half_tile_size) return .e3
            else if (location.y > f - half_tile_size) return .f3
            else if (location.y > g - half_tile_size) return .g3
            else return .h3;
        } else if (location.x < @"4" + half_tile_size) {
            if (location.y > a - half_tile_size) return .a4
            else if (location.y > b - half_tile_size) return .b4
            else if (location.y > c - half_tile_size) return .c4
            else if (location.y > d - half_tile_size) return .d4
            else if (location.y > e - half_tile_size) return .e4
            else if (location.y > f - half_tile_size) return .f4
            else if (location.y > g - half_tile_size) return .g4
            else return .h4;
        } else if (location.x < @"5" + half_tile_size) {
            if (location.y > a - half_tile_size) return .a5
            else if (location.y > b - half_tile_size) return .b5
            else if (location.y > c - half_tile_size) return .c5
            else if (location.y > d - half_tile_size) return .d5
            else if (location.y > e - half_tile_size) return .e5
            else if (location.y > f - half_tile_size) return .f5
            else if (location.y > g - half_tile_size) return .g5
            else return .h5;
        } else if (location.x < @"6" + half_tile_size) {
            if (location.y > a - half_tile_size) return .a6
            else if (location.y > b - half_tile_size) return .b6
            else if (location.y > c - half_tile_size) return .c6
            else if (location.y > d - half_tile_size) return .d6
            else if (location.y > e - half_tile_size) return .e6
            else if (location.y > f - half_tile_size) return .f6
            else if (location.y > g - half_tile_size) return .g6
            else return .h6;
        } else if (location.x < @"7" + half_tile_size) {
            if (location.y > a - half_tile_size) return .a7
            else if (location.y > b - half_tile_size) return .b7
            else if (location.y > c - half_tile_size) return .c7
            else if (location.y > d - half_tile_size) return .d7
            else if (location.y > e - half_tile_size) return .e7
            else if (location.y > f - half_tile_size) return .f7
            else if (location.y > g - half_tile_size) return .g7
            else return .h7;
        } else {
            if (location.y > a - half_tile_size) return .a8
            else if (location.y > b - half_tile_size) return .b8
            else if (location.y > c - half_tile_size) return .c8
            else if (location.y > d - half_tile_size) return .d8
            else if (location.y > e - half_tile_size) return .e8
            else if (location.y > f - half_tile_size) return .f8
            else if (location.y > g - half_tile_size) return .g8
            else return .h8;
        }
    }

    pub fn toTransform(self: Coord) Mat3x4 {
        return switch(self) {
            .a1 => Mat3x4.from_translation(F32x3.new(a, 0.0, @"1")),
            .a2 => Mat3x4.from_translation(F32x3.new(a, 0.0, @"2")),
            .a3 => Mat3x4.from_translation(F32x3.new(a, 0.0, @"3")),
            .a4 => Mat3x4.from_translation(F32x3.new(a, 0.0, @"4")),
            .a5 => Mat3x4.from_translation(F32x3.new(a, 0.0, @"5")),
            .a6 => Mat3x4.from_translation(F32x3.new(a, 0.0, @"6")),
            .a7 => Mat3x4.from_translation(F32x3.new(a, 0.0, @"7")),
            .a8 => Mat3x4.from_translation(F32x3.new(a, 0.0, @"8")),
            .b1 => Mat3x4.from_translation(F32x3.new(b, 0.0, @"1")),
            .b2 => Mat3x4.from_translation(F32x3.new(b, 0.0, @"2")),
            .b3 => Mat3x4.from_translation(F32x3.new(b, 0.0, @"3")),
            .b4 => Mat3x4.from_translation(F32x3.new(b, 0.0, @"4")),
            .b5 => Mat3x4.from_translation(F32x3.new(b, 0.0, @"5")),
            .b6 => Mat3x4.from_translation(F32x3.new(b, 0.0, @"6")),
            .b7 => Mat3x4.from_translation(F32x3.new(b, 0.0, @"7")),
            .b8 => Mat3x4.from_translation(F32x3.new(b, 0.0, @"8")),
            .c1 => Mat3x4.from_translation(F32x3.new(c, 0.0, @"1")),
            .c2 => Mat3x4.from_translation(F32x3.new(c, 0.0, @"2")),
            .c3 => Mat3x4.from_translation(F32x3.new(c, 0.0, @"3")),
            .c4 => Mat3x4.from_translation(F32x3.new(c, 0.0, @"4")),
            .c5 => Mat3x4.from_translation(F32x3.new(c, 0.0, @"5")),
            .c6 => Mat3x4.from_translation(F32x3.new(c, 0.0, @"6")),
            .c7 => Mat3x4.from_translation(F32x3.new(c, 0.0, @"7")),
            .c8 => Mat3x4.from_translation(F32x3.new(c, 0.0, @"8")),
            .d1 => Mat3x4.from_translation(F32x3.new(d, 0.0, @"1")),
            .d2 => Mat3x4.from_translation(F32x3.new(d, 0.0, @"2")),
            .d3 => Mat3x4.from_translation(F32x3.new(d, 0.0, @"3")),
            .d4 => Mat3x4.from_translation(F32x3.new(d, 0.0, @"4")),
            .d5 => Mat3x4.from_translation(F32x3.new(d, 0.0, @"5")),
            .d6 => Mat3x4.from_translation(F32x3.new(d, 0.0, @"6")),
            .d7 => Mat3x4.from_translation(F32x3.new(d, 0.0, @"7")),
            .d8 => Mat3x4.from_translation(F32x3.new(d, 0.0, @"8")),
            .e1 => Mat3x4.from_translation(F32x3.new(e, 0.0, @"1")),
            .e2 => Mat3x4.from_translation(F32x3.new(e, 0.0, @"2")),
            .e3 => Mat3x4.from_translation(F32x3.new(e, 0.0, @"3")),
            .e4 => Mat3x4.from_translation(F32x3.new(e, 0.0, @"4")),
            .e5 => Mat3x4.from_translation(F32x3.new(e, 0.0, @"5")),
            .e6 => Mat3x4.from_translation(F32x3.new(e, 0.0, @"6")),
            .e7 => Mat3x4.from_translation(F32x3.new(e, 0.0, @"7")),
            .e8 => Mat3x4.from_translation(F32x3.new(e, 0.0, @"8")),
            .f1 => Mat3x4.from_translation(F32x3.new(f, 0.0, @"1")),
            .f2 => Mat3x4.from_translation(F32x3.new(f, 0.0, @"2")),
            .f3 => Mat3x4.from_translation(F32x3.new(f, 0.0, @"3")),
            .f4 => Mat3x4.from_translation(F32x3.new(f, 0.0, @"4")),
            .f5 => Mat3x4.from_translation(F32x3.new(f, 0.0, @"5")),
            .f6 => Mat3x4.from_translation(F32x3.new(f, 0.0, @"6")),
            .f7 => Mat3x4.from_translation(F32x3.new(f, 0.0, @"7")),
            .f8 => Mat3x4.from_translation(F32x3.new(f, 0.0, @"8")),
            .g1 => Mat3x4.from_translation(F32x3.new(g, 0.0, @"1")),
            .g2 => Mat3x4.from_translation(F32x3.new(g, 0.0, @"2")),
            .g3 => Mat3x4.from_translation(F32x3.new(g, 0.0, @"3")),
            .g4 => Mat3x4.from_translation(F32x3.new(g, 0.0, @"4")),
            .g5 => Mat3x4.from_translation(F32x3.new(g, 0.0, @"5")),
            .g6 => Mat3x4.from_translation(F32x3.new(g, 0.0, @"6")),
            .g7 => Mat3x4.from_translation(F32x3.new(g, 0.0, @"7")),
            .g8 => Mat3x4.from_translation(F32x3.new(g, 0.0, @"8")),
            .h1 => Mat3x4.from_translation(F32x3.new(h, 0.0, @"1")),
            .h2 => Mat3x4.from_translation(F32x3.new(h, 0.0, @"2")),
            .h3 => Mat3x4.from_translation(F32x3.new(h, 0.0, @"3")),
            .h4 => Mat3x4.from_translation(F32x3.new(h, 0.0, @"4")),
            .h5 => Mat3x4.from_translation(F32x3.new(h, 0.0, @"5")),
            .h6 => Mat3x4.from_translation(F32x3.new(h, 0.0, @"6")),
            .h7 => Mat3x4.from_translation(F32x3.new(h, 0.0, @"7")),
            .h8 => Mat3x4.from_translation(F32x3.new(h, 0.0, @"8")),
        };
    }
};