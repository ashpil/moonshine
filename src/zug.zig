const math = @import("std").math;

fn checkValidVecT(comptime T: type) void {
    if (!(@typeInfo(T) == .Float or @typeInfo(T) == .Int)) {
        @compileError("You dum dum, you can't do addition over " ++ @typeName(T) ++ "!");
    }
}

fn intToT(comptime T: type, int: comptime_int) T {
    if (@typeInfo(T) == .Float) return @intToFloat(T, int);
    return @intCast(T, int);
}

pub fn Vec2(comptime T: type) type {
    checkValidVecT(T);

    return extern struct {
        x: T,
        y: T,

        const Self = @This();

        pub fn new(x: T, y: T) Self {
            return Self { .x = x, .y = y };
        }
    };

}

pub fn Vec3(comptime T: type) type {
    checkValidVecT(T);

    return extern struct {
        x: T,
        y: T,
        z: T,

        const Self = @This();

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

        pub fn unit(self: Self) Self {
            return self.div_scalar(self.length());
        }

        pub fn length(self: Self) T {
            return math.sqrt(self.dot(self));
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

        pub const e_0 = Self.new(one, zero, zero, zero);
        pub const e_1 = Self.new(zero, one, zero, zero);
        pub const e_2 = Self.new(zero, zero, one, zero);
        pub const e_3 = Self.new(zero, zero, zero, one);

        pub fn new(x: T, y: T, z: T, w: T) Self {
            return Self { .x = x, .y = y, .z = z, .w = w };
        }

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
            pub fn fromAxisAngle(radians: T, axis: Vec3T) Self {
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
