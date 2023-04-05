// TODO: should this be replaced by/use @Vector?
// TODO: make sure everything here is consistent in naming/structure

const std = @import("std");
const math = std.math;

fn checkValidVecT(comptime T: type) void {
    if (!(@typeInfo(T) == .Float or @typeInfo(T) == .Int)) {
        @compileError("You dum dum, you can't do addition over " ++ @typeName(T) ++ "!");
    }
}

fn intToT(comptime T: type, comptime int: comptime_int) T {
    if (@typeInfo(T) == .Float) return @intToFloat(T, int);
    return @intCast(T, int);
}

pub fn Vec2(comptime T: type) type {
    checkValidVecT(T);

    return extern struct {
        x: T,
        y: T,

        pub const element_count = 2;
        pub const Inner = T;

        const Self = @This();

        pub fn new(x: T, y: T) Self {
            return Self { .x = x, .y = y };
        }

        pub fn mul_scalar(self: Self, scalar: T) Self {
            return Self.new(self.x * scalar, self.y * scalar);
        }

        pub fn mul(self: Self, other: Self) Self {
            return Self.new(self.x * other.x, self.y * other.y);
        }

        pub fn div_scalar(self: Self, scalar: T) Self {
            return Self.new(self.x / scalar, self.y / scalar);
        }

        pub fn div(self: Self, other: Self) Self {
            return Self.new(self.x / other.x, self.y / other.y);
        }

        pub fn dot(self: Self, other: Self) T {
            return self.x * other.x + self.y * other.y;
        }

        pub fn sub(self: Self, other: Self) Self {
            return Self.new(self.x - other.x, self.y - other.y);
        }

        pub fn add(self: Self, other: Self) Self {
            return Self.new(self.x + other.x, self.y + other.y);
        }

        pub fn unit(self: Self) Self {
            return self.div_scalar(self.length());
        }

        pub fn length(self: Self) T {
            return math.sqrt(self.dot(self));
        }

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll("{ ");
            try std.fmt.formatType(self.x, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(", ");
            try std.fmt.formatType(self.y, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(" }");
        }
    };

}

pub fn Vec3(comptime T: type) type {
    checkValidVecT(T);

    const Vec4T = Vec4(T);

    return extern struct {
        x: T,
        y: T,
        z: T,

        const Self = @This();

        const zero = intToT(T, 0);
        const one = intToT(T, 1);

        pub const element_count = 3;
        pub const Inner = T;

        pub const e_0 = Self.new(one, zero, zero);
        pub const e_1 = Self.new(zero, one, zero);
        pub const e_2 = Self.new(zero, zero, one);

        pub fn new(x: T, y: T, z: T) Self {
            return Self { .x = x, .y = y, .z = z };
        }

        pub fn mul_scalar(self: Self, scalar: T) Self {
            return Self.new(self.x * scalar, self.y * scalar, self.z * scalar);
        }

        pub fn mul(self: Self, other: Self) Self {
            return Self.new(self.x * other.x, self.y * other.y, self.z * other.z);
        }

        pub fn div_scalar(self: Self, scalar: T) Self {
            return Self.new(self.x / scalar, self.y / scalar, self.z / scalar);
        }

        pub fn div(self: Self, other: Self) Self {
            return Self.new(self.x / other.x, self.y / other.y, self.z / other.z);
        }

        pub fn dot(self: Self, other: Self) T {
            return self.x * other.x + self.y * other.y + self.z * other.z;
        }

        pub fn cross(self: Self, other: Self) Self {
            const x = self.y * other.z - other.y * self.z;
            const y = self.z * other.x - other.z * self.x;
            const z = self.x * other.y - other.x * self.y;
            return Self.new(x, y, z);
        }

        pub fn sub(self: Self, other: Self) Self {
            return Self.new(self.x - other.x, self.y - other.y, self.z - other.z);
        }

        pub fn add(self: Self, other: Self) Self {
            return Self.new(self.x + other.x, self.y + other.y, self.z + other.z);
        }

        pub fn unit(self: Self) Self {
            return self.div_scalar(self.length());
        }

        pub fn length(self: Self) T {
            return math.sqrt(self.dot(self));
        }

        pub fn extend(self: Self, w: T) Vec4T {
            return Vec4T.new(self.x, self.y, self.z, w);
        }

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll("{ ");
            try std.fmt.formatType(self.x, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(", ");
            try std.fmt.formatType(self.y, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(", ");
            try std.fmt.formatType(self.z, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(" }");
        }
    };
}

pub fn Vec4(comptime T: type) type {
    checkValidVecT(T);

    return extern struct {
        x: T,
        y: T,
        z: T,
        w: T,

        const Self = @This();

        const zero = intToT(T, 0);
        const one = intToT(T, 1);

        pub const element_count = 4;
        pub const Inner = T;

        pub const e_0 = Self.new(one, zero, zero, zero);
        pub const e_1 = Self.new(zero, one, zero, zero);
        pub const e_2 = Self.new(zero, zero, one, zero);
        pub const e_3 = Self.new(zero, zero, zero, one);

        pub fn new(x: T, y: T, z: T, w: T) Self {
            return Self { .x = x, .y = y, .z = z, .w = w };
        }

        pub fn dot(self: Self, other: Self) T {
            return self.x * other.x + self.y * other.y + self.z * other.z + self.w * other.w;
        }

        pub fn sum(self: Self) T {
            return self.x + self.y + self.z + self.w;
        }

        pub fn truncate(self: Self) Vec3(T) {
            return Vec3(T).new(self.x, self.y, self.z);
        }

        pub fn mul_scalar(self: Self, scalar: T) Self {
            return Self.new(self.x * scalar, self.y * scalar, self.z * scalar, self.w * scalar);
        }

        pub fn add(self: Self, other: Self) Self {
            return Self.new(self.x + other.x, self.y + other.y, self.z + other.z, self.w + other.w);
        }

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll("{ ");
            try std.fmt.formatType(self.x, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(", ");
            try std.fmt.formatType(self.y, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(", ");
            try std.fmt.formatType(self.z, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(", ");
            try std.fmt.formatType(self.w, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(" }");
        }
    };
}

pub fn Mat4x3(comptime T: type) type {
    checkValidVecT(T);

    const Vec3T = Vec3(T);

    return extern struct {
        x: Vec3T,
        y: Vec3T,
        z: Vec3T,
        w: Vec3T,

        const Self = @This();

        pub fn new(x: Vec3T, y: Vec3T, z: Vec3T, w: Vec3T) Self {
            return Self { .x = x, .y = y, .z = z, .w = w };
        }
    };
}

pub fn Mat3x4(comptime T: type) type {
    checkValidVecT(T);

    const Vec4T = Vec4(T);
    const Vec3T = Vec3(T);
    const Mat4x3T = Mat4x3(T);
    const Mat3T = Mat3(T);

    return extern struct {
        x: Vec4T,
        y: Vec4T,
        z: Vec4T,

        const Self = @This();

        pub const identity = Self.new(Vec4T.e_0, Vec4T.e_1, Vec4T.e_2);

        pub fn new(x: Vec4T, y: Vec4T, z: Vec4T) Self {
            return Self { .x = x, .y = y, .z = z };
        }

        pub fn from_translation(v: Vec3T) Self {
            return Self {
                .x = Vec3T.e_0.extend(v.x),
                .y = Vec3T.e_1.extend(v.y),
                .z = Vec3T.e_2.extend(v.z),
            };
        }

        pub fn transpose(self: Self) Mat4x3T {
            return Mat4x3T.new(
                Vec3T.new(self.x.x, self.y.x, self.z.x),
                Vec3T.new(self.x.y, self.y.y, self.z.y),
                Vec3T.new(self.x.z, self.y.z, self.z.z),
                Vec3T.new(self.x.w, self.y.w, self.z.w),
            );
        }

        pub fn mul_point(self: Self, v: Vec3T) Vec3T {
            const x = self.x.dot(v.extend(1.0));
            const y = self.y.dot(v.extend(1.0));
            const z = self.z.dot(v.extend(1.0));
            return Vec3T.new(x, y, z);
        }

        pub fn mul_vec(self: Self, v: Vec3T) Vec3T {
            const x = self.x.dot(v.extend(0.0));
            const y = self.y.dot(v.extend(0.0));
            const z = self.z.dot(v.extend(0.0));
            return Vec3T.new(x, y, z);
        }

        pub fn mul(self: Self, other: Self) Self {
            const transposed = other.transpose();
            return Self.new(
                Vec4T.new(self.x.dot(transposed.x.extend(0.0)), self.x.dot(transposed.y.extend(0.0)), self.x.dot(transposed.z.extend(0.0)), self.x.dot(transposed.w.extend(1.0))),
                Vec4T.new(self.y.dot(transposed.x.extend(0.0)), self.y.dot(transposed.y.extend(0.0)), self.y.dot(transposed.z.extend(0.0)), self.y.dot(transposed.w.extend(1.0))),
                Vec4T.new(self.z.dot(transposed.x.extend(0.0)), self.z.dot(transposed.y.extend(0.0)), self.z.dot(transposed.z.extend(0.0)), self.z.dot(transposed.w.extend(1.0))),
            );
        }

        pub fn extract_translation(self: Self) Vec3T {
            return Vec3T.new(self.x.w, self.y.w, self.z.w);
        }

        pub fn with_translation(self: Self, v: Vec3T) Self {
            var self_mut = self;
            self_mut.x.w = v.x;
            self_mut.y.w = v.y;
            self_mut.z.w = v.z;
            return self_mut;
        }

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll("{ ");
            try std.fmt.formatType(self.x, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(", ");
            try std.fmt.formatType(self.y, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(", ");
            try std.fmt.formatType(self.z, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(" }");
        }

        pub usingnamespace if (@typeInfo(T) != .Float) struct {} else struct {
            pub fn from_rotation(axis: Vec3T, angle: f32) Self {
                const sin = math.sin(angle);
                const cos = math.cos(angle);

                const axissin = axis.mul_scalar(sin);
                const axis2 = axis.mul(axis);

                const omc = 1.0 - cos;

                const xyomc = axis.x * axis.y * omc;
                const xzomc = axis.x * axis.z * omc;
                const yzomc = axis.y * axis.z * omc;

                return Self.new(
                    Vec4T.new(axis2.x * omc + cos, xyomc + axissin.z, xzomc - axissin.y, 0.0),
                    Vec4T.new(xyomc - axissin.z, axis2.y * omc + cos, yzomc + axissin.x, 0.0),
                    Vec4T.new(xzomc + axissin.y, yzomc - axissin.x, axis2.z * omc + cos, 0.0),
                );
            }

            // https://math.stackexchange.com/a/152686
            pub fn inverse_affine(self: Self) Self {
                const p = Mat3T.new(self.x.truncate(), self.y.truncate(), self.z.truncate()).transpose();
                const v = Vec3T.new(self.x.w, self.y.w, self.z.w);

                const inv_p = p.inverse();
                const neg_inv_p_v = inv_p.mul_scalar(-1).mul_vec(v);

                return Self.new(
                    Vec4T.new(inv_p.x.x, inv_p.y.x, inv_p.z.x, neg_inv_p_v.x),
                    Vec4T.new(inv_p.x.y, inv_p.y.y, inv_p.z.y, neg_inv_p_v.y),
                    Vec4T.new(inv_p.x.z, inv_p.y.z, inv_p.z.z, neg_inv_p_v.z),
                );
            }
        };

    };
}

pub fn Mat4(comptime T: type) type {
    checkValidVecT(T);

    const Vec4T = Vec4(T);
    const Vec3T = Vec3(T);

    return extern struct {
        x: Vec4T,
        y: Vec4T,
        z: Vec4T,
        w: Vec4T,

        const Self = @This();

        pub const identity = Self.new(Vec4T.e_0, Vec4T.e_1, Vec4T.e_2, Vec4T.e_3);

        pub fn new(x: Vec4T, y: Vec4T, z: Vec4T, w: Vec4T) Self {
            return Self { .x = x, .y = y, .z = z, .w = w };
        }

        pub fn mul_point(self: Self, v: Vec3T) Vec3T {
            var res = self.x.mul_scalar(v.x);
            res = self.y.mul_scalar(v.y).add(res);
            res = self.z.mul_scalar(v.z).add(res);
            res = self.w.add(res);
            return Vec3T.new(res.x, res.y, res.z);
        }

        pub fn mul_vec(self: Self, v: Vec3T) Vec3T {
            var res = self.x.mul_scalar(v.x);
            res = self.y.mul_scalar(v.y).add(res);
            res = self.z.mul_scalar(v.z).add(res);
            return Vec3T.new(res.x, res.y, res.z);
        }

        pub fn lookAt(eye: Vec3T, target: Vec3T, up: Vec3T) Self {
            const f = eye.sub(target).unit();
            const s = up.cross(f).unit();
            const u = f.cross(s);

            const zero = intToT(T, 0);

            const x = Vec4T.new(s.x, u.x, f.x, zero);
            const y = Vec4T.new(s.y, u.y, f.y, zero);
            const z = Vec4T.new(s.z, u.z, f.z, zero);
            const w = Vec4T.new(-s.dot(eye), -u.dot(eye), -f.dot(eye), intToT(T, 1));

            return Self.new(x, y, z, w);
        }

        pub usingnamespace if (@typeInfo(T) != .Float) struct {} else struct {
            pub fn fromAxisAngle(axis: Vec3T, radians: T) Self {
                const axis_sin = axis.mul_scalar(math.sin(radians));
                const cos = math.cos(radians);
                const axis_sq = axis.mul(axis);
                const omc = 1.0 - cos;
                const xyomc = axis.x * axis.y * omc;
                const xzomc = axis.x * axis.z * omc;
                const yzomc = axis.y * axis.z * omc;

                const x = Vec4T.new(
                    axis_sq.x * omc + cos,
                    xyomc + axis_sin.z,
                    xzomc - axis_sin.y,
                    0.0
                );
                const y = Vec4T.new(
                    xyomc - axis_sin.z,
                    axis_sq.y * omc + cos,
                    yzomc + axis_sin.x,
                    0.0
                );
                const z = Vec4T.new(
                    xzomc + axis_sin.y,
                    yzomc - axis_sin.x,
                    axis_sq.z * omc + cos,
                    0.0
                );

                return Self.new(x, y, z, Vec4T.e_3);
            }

            pub fn perspective(vfov: T, aspect_ratio: T, near: T, far: T) Self {
                const vfov_2 = vfov / 2.0;
                const sin = math.sin(vfov_2);
                const cos = math.cos(vfov_2);
                const h = cos / sin;
                const t = h / aspect_ratio;
                const r = far / (near - far);

                const x = Vec4T.new(t, 0.0, 0.0, 0.0);
                const y = Vec4T.new(0.0, -h, 0.0, 0.0);
                const z = Vec4T.new(0.0, 0.0, r, -1.0);
                const w = Vec4T.new(0.0, 0.0, r * near, 0.0);

                return Self.new(x, y, z, w);
            }
        };
    };
}

pub fn Mat3(comptime T: type) type {
    checkValidVecT(T);

    const Vec3T = Vec3(T);

    return extern struct {
        x: Vec3T,
        y: Vec3T,
        z: Vec3T,

        const Self = @This();

        pub const identity = Self.new(Vec3T.e_0, Vec3T.e_1, Vec3T.e_2);

        pub fn new(x: Vec3T, y: Vec3T, z: Vec3T) Self {
            return Self { .x = x, .y = y, .z = z };
        }

        pub fn mul_vec(self: Self, v: Vec3T) Vec3T {
            var res = self.x.mul_scalar(v.x);
            res = self.y.mul_scalar(v.y).add(res);
            res = self.z.mul_scalar(v.z).add(res);
            return res;
        }

        pub fn mul_scalar(self: Self, scalar: T) Self {
            const x = self.x.mul_scalar(scalar);
            const y = self.y.mul_scalar(scalar);
            const z = self.z.mul_scalar(scalar);
            return Self.new(x, y, z);
        }

        pub fn determinant(self: Self) T {
            return self.x.dot(self.y.cross(self.z));
        }

        pub fn transpose(self: Self) Self {
            return Self.new(
                Vec3T.new(self.x.x, self.y.x, self.z.x),
                Vec3T.new(self.x.y, self.y.y, self.z.y),
                Vec3T.new(self.x.z, self.y.z, self.z.z),
            );
        }

        pub usingnamespace if (@typeInfo(T) != .Float) struct {} else struct {
            pub fn inverse(self: Self) Self {
                const det = self.determinant();
                std.debug.assert(det != 0);
                const v1 = self.y.cross(self.z).mul_scalar(1 / det);
                const v2 = self.z.cross(self.x).mul_scalar(1 / det);
                const v3 = self.x.cross(self.y).mul_scalar(1 / det);
                return Self.new(v1, v2, v3).transpose();
            }
        };
    };
}

