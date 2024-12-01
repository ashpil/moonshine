// all matrices are row-major

const std = @import("std");
const math = std.math;

fn checkValidVecT(comptime T: type) void {
    if (!(@typeInfo(T) == .float or @typeInfo(T) == .int)) {
        @compileError("You dum dum, you can't do addition over " ++ @typeName(T) ++ "!");
    }
}

pub fn Vec2(comptime T: type) type {
    checkValidVecT(T);

    return extern struct {
        x: T,
        y: T,

        pub const ComponentType = T;

        pub const element_count = 2;

        pub const zero = Self.new(0, 0);

        pub const e_0 = Self.new(1, 0);
        pub const e_1 = Self.new(0, 1);

        const Self = @This();

        pub fn new(x: T, y: T) Self {
            return Self { .x = x, .y = y };
        }

        pub fn scale(self: Self, scalar: T) Self {
            return Self.new(self.x * scalar, self.y * scalar);
        }

        pub fn componentMul(self: Self, other: Self) Self {
            return Self.new(self.x * other.x, self.y * other.y);
        }

        pub fn componentDiv(self: Self, other: Self) Self {
            return Self.new(self.x / other.x, self.y / other.y);
        }

        pub fn dot(self: Self, other: Self) T {
            return self.componentMul(other).sum();
        }

        pub fn sub(self: Self, other: Self) Self {
            return Self.new(self.x - other.x, self.y - other.y);
        }

        pub fn add(self: Self, other: Self) Self {
            return Self.new(self.x + other.x, self.y + other.y);
        }

        pub fn sum(self: Self) T {
            return self.x + self.y;
        }

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll("{ ");
            try std.fmt.formatType(self.x, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(", ");
            try std.fmt.formatType(self.y, fmt, options, writer, std.fmt.default_max_depth);
            try writer.writeAll(" }");
        }

        pub usingnamespace if (@typeInfo(T) == .float) struct {
            pub fn normL2(self: Self) T {
                return math.sqrt(self.dot(self));
            }

            pub fn unit(self: Self) Self {
                return self.scale(1 / self.normL2());
            }
        } else struct {};
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

        pub const ComponentType = T;

        pub const element_count = 3;

        pub const zero = Self.new(0, 0, 0);

        pub const e_0 = Self.new(1, 0, 0);
        pub const e_1 = Self.new(0, 1, 0);
        pub const e_2 = Self.new(0, 0, 1);

        pub fn new(x: T, y: T, z: T) Self {
            return Self { .x = x, .y = y, .z = z };
        }

        pub fn scale(self: Self, scalar: T) Self {
            return Self.new(self.x * scalar, self.y * scalar, self.z * scalar);
        }

        pub fn componentMul(self: Self, other: Self) Self {
            return Self.new(self.x * other.x, self.y * other.y, self.z * other.z);
        }

        pub fn componentDiv(self: Self, other: Self) Self {
            return Self.new(self.x / other.x, self.y / other.y, self.z / other.z);
        }

        pub fn dot(self: Self, other: Self) T {
            return self.componentMul(other).sum();
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

        pub fn sum(self: Self) T {
            return self.x + self.y + self.z;
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

        pub usingnamespace if (@typeInfo(T) == .float) struct {
            pub fn normL2(self: Self) T {
                return math.sqrt(self.dot(self));
            }

            pub fn unit(self: Self) Self {
                return self.scale(1 / self.normL2());
            }
        } else struct {};
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

        pub const ComponentType = T;

        pub const element_count = 4;

        pub const zero = Self.new(0, 0, 0, 0);

        pub const e_0 = Self.new(1, 0, 0, 0);
        pub const e_1 = Self.new(0, 1, 0, 0);
        pub const e_2 = Self.new(0, 0, 1, 0);
        pub const e_3 = Self.new(0, 0, 0, 1);

        pub fn new(x: T, y: T, z: T, w: T) Self {
            return Self { .x = x, .y = y, .z = z, .w = w };
        }

        pub fn scale(self: Self, scalar: T) Self {
            return Self.new(self.x * scalar, self.y * scalar, self.z * scalar, self.w * scalar);
        }

        pub fn componentMul(self: Self, other: Self) Self {
            return Self.new(self.x * other.x, self.y * other.y, self.z * other.z, self.w * other.w);
        }

        pub fn componentDiv(self: Self, other: Self) Self {
            return Self.new(self.x / other.x, self.y / other.y, self.z / other.z, self.w / other.w);
        }

        pub fn dot(self: Self, other: Self) T {
            return self.componentMul(other).sum();
        }

        pub fn sum(self: Self) T {
            return self.x + self.y + self.z + self.w;
        }

        pub fn truncate(self: Self) Vec3(T) {
            return Vec3(T).new(self.x, self.y, self.z);
        }

        pub fn sub(self: Self, other: Self) Self {
            return Self.new(self.x - other.x, self.y - other.y, self.z - other.z, self.w - other.w);
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

        pub usingnamespace if (@typeInfo(T) == .float) struct {
            pub fn normL2(self: Self) T {
                return math.sqrt(self.dot(self));
            }

            pub fn unit(self: Self) Self {
                return self.scale(1 / self.normL2());
            }
        } else struct {};
    };
}

pub fn Mat3x4(comptime T: type) type {
    checkValidVecT(T);

    const Vec4T = Vec4(T);
    const Vec3T = Vec3(T);
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

        pub fn fromTranslation(v: Vec3T) Self {
            return Self {
                .x = Vec3T.e_0.extend(v.x),
                .y = Vec3T.e_1.extend(v.y),
                .z = Vec3T.e_2.extend(v.z),
            };
        }

        pub fn mulPoint(self: Self, v: Vec3T) Vec3T {
            const x = self.x.dot(v.extend(1.0));
            const y = self.y.dot(v.extend(1.0));
            const z = self.z.dot(v.extend(1.0));
            return Vec3T.new(x, y, z);
        }

        pub fn mulVector(self: Self, v: Vec3T) Vec3T {
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

        pub fn extractTranslation(self: Self) Vec3T {
            return Vec3T.new(self.x.w, self.y.w, self.z.w);
        }

        pub fn truncate(self: Self) Mat3T {
            return Mat3T.new(self.x.truncate(), self.y.truncate(), self.z.truncate());
        }

        pub fn withTranslation(self: Self, v: Vec3T) Self {
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

        pub usingnamespace if (@typeInfo(T) == .float) struct {
            // https://math.stackexchange.com/a/152686
            pub fn inverseAffine(self: Self) Self {
                const p = self.truncate();
                const v = self.extractTranslation();

                const inv_p = p.inverse();
                const neg_inv_p_v = inv_p.scale(-1).mulVector(v);

                return Self.new(
                    Vec4T.new(inv_p.x.x, inv_p.y.x, inv_p.z.x, neg_inv_p_v.x),
                    Vec4T.new(inv_p.x.y, inv_p.y.y, inv_p.z.y, neg_inv_p_v.y),
                    Vec4T.new(inv_p.x.z, inv_p.y.z, inv_p.z.z, neg_inv_p_v.z),
                );
            }
        } else struct {};
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

        pub fn mulVector(self: Self, v: Vec3T) Vec3T {
            return Vec3T.new(
                self.x.dot(v),
                self.y.dot(v),
                self.z.dot(v),
            );
        }

        pub fn scale(self: Self, scalar: T) Self {
            const x = self.x.scale(scalar);
            const y = self.y.scale(scalar);
            const z = self.z.scale(scalar);
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

        pub usingnamespace if (@typeInfo(T) == .float) struct {
            pub fn inverse(self: Self) Self {
                const det = self.determinant();
                std.debug.assert(det != 0);
                const v1 = self.y.cross(self.z).scale(1 / det);
                const v2 = self.z.cross(self.x).scale(1 / det);
                const v3 = self.x.cross(self.y).scale(1 / det);
                return Self.new(v1, v2, v3);
            }
        } else struct {};
    };
}

