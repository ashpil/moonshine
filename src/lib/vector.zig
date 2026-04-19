const std = @import("std");

fn MatrixProduct(Left: type, Right: type) type {
    if (Left.ComponentType != Right.ComponentType) @compileError("Component types must be matching, but left is " ++ @typeName(Left.ComponentType) ++ " and right is " ++ @typeName(Right.ComponentType));
    if (Left.col_count != Right.row_count) @compileError(std.fmt.comptimePrint("Left column count must match right row count, but left column count is {} and right row count is {}", .{ Left.col_count, Right.row_count }));
    return Matrix(Left.ComponentType, Right.col_count, Left.row_count);
}

fn isNumberType(T: type) bool {
    return isIntegerType(T) or isFloatType(T);
}

fn isFloatType(T: type) bool {
    return switch (@typeInfo(T)) {
       .comptime_float, .float => true,
        else => false,
    };
}

fn isIntegerType(T: type) bool {
    return switch (@typeInfo(T)) {
       .comptime_int, .int => true,
        else => false,
    };
}

// a major design goal here is that the storage medium is abstracted away from the API
// internally this could be row major, column major, morton order, etc. shouldn't matter
// to the user of the matrix
pub fn Matrix(comptime T: type, comptime c: comptime_int, comptime r: comptime_int) type {
    if (c <= 0) @compileError(std.fmt.comptimePrint("Matrix must have positive column count, but has {} columns", .{ c }));
    if (r <= 0) @compileError(std.fmt.comptimePrint("Matrix must have positive row count, but has {} rows", .{ r }));

    // but technically... it has a well defined extern row-major layout so that it's easy
    // to pass it around to extern places
    return extern struct {
        storage: [row_count][col_count]ComponentType,

        const Self = @This();

        pub const ComponentType = T;
        pub const col_count = c;
        pub const row_count = r;
        pub const element_count = col_count * row_count;

        pub const Transpose = Matrix(T, row_count, col_count);
        pub const Col = Matrix(T, 1, row_count);
        pub const Row = Matrix(T, col_count, 1);

        pub const ColIndex = std.math.IntFittingRange(0, col_count);
        pub const RowIndex = std.math.IntFittingRange(0, row_count);
        pub const Index = if (col_count == 1 and row_count == 1) struct {
            col: ColIndex = 0,
            row: RowIndex = 0,
        } else if (col_count == 1) struct {
            col: ColIndex = 0,
            row: RowIndex,
        } else if (row_count == 1) struct {
            col: ColIndex,
            row: RowIndex = 0,
        } else struct {
            col: ColIndex,
            row: RowIndex,
        };

        // this is the only method that has knowledge of the underlying storage -- it's abstracted away from everything else
        pub fn at_mut(self: *Self, index: Index) *ComponentType {
            return &self.storage[index.row][index.col];
        }

        pub fn at(self: Self, index: Index) ComponentType {
            var mut = self;
            return mut.at_mut(index).*;
        }

        pub fn transpose(self: Self) Transpose {
            var out: Transpose = undefined;
            inline for (0..col_count) |col_idx| {
                inline for (0..row_count) |row_idx| {
                    out.at_mut(.{ .col = row_idx, .row = col_idx }).* = self.at(.{ .row = row_idx, .col = col_idx });
                }
            }
            return out;
        }

        pub fn col(self: Self, index: std.math.IntFittingRange(0, col_count)) Col {
            var out: Col = undefined;
            inline for (0..row_count) |row_idx| {
                out.at_mut(.{ .row = row_idx }).* = self.at(.{ .col = index, .row = row_idx});
            }
            return out;
        }

        pub fn cols(self: Self) [col_count]Col {
            var out: [col_count]Col = undefined;
            inline for (0..col_count) |col_idx| {
                out[col_idx] = self.col(col_idx);
            }
            return out;
        }

        pub fn row(self: Self, index: std.math.IntFittingRange(0, row_count)) Row {
            var out: Row = undefined;
            inline for (0..col_count) |col_idx| {
                out.at_mut(.{ .col = col_idx }).* = self.at(.{ .row = index, .col = col_idx});
            }
            return out;
        }

        pub fn rows(self: Self) [row_count]Row {
            var out: [row_count]Row = undefined;
            inline for (0..row_count) |row_idx| {
                out[row_idx] = self.row(row_idx);
            }
            return out;
        }

        pub fn fromCols(values: [col_count]Col) Self {
            var out: Self = undefined;
            inline for (0..col_count) |col_idx| {
                inline for (0..row_count) |row_idx| {
                    out.at_mut(.{ .col = col_idx, .row = row_idx }).* = values[col_idx].at(.{ .row = row_idx });
                }
            }
            return out;
        }

        pub fn fromRows(values: [row_count]Row) Self {
            var out: Self = undefined;
            inline for (0..col_count) |col_idx| {
                inline for (0..row_count) |row_idx| {
                    out.at_mut(.{ .col = col_idx, .row = row_idx }).* = values[row_idx].at(.{ .col = col_idx });
                }
            }
            return out;
        }

        pub fn splat(value: ComponentType) Self {
            var out: Self = undefined;
            inline for (0..col_count) |col_idx| {
                inline for (0..row_count) |row_idx| {
                    out.at_mut(.{ .col = col_idx, .row = row_idx }).* = value;
                }
            }
            return out;
        }

        pub fn appendCol(self: Self, to_append: Col) Matrix(ComponentType, col_count + 1, row_count) {
            return .fromCols(self.cols() ++ .{ to_append });
        }

        const MultipleCols = if (col_count > 1) struct {
            pub fn withoutCol(self: Self, comptime index: ColIndex) Matrix(ComponentType, col_count - 1, row_count) {
                return .fromCols(self.cols()[0..index].* ++ self.cols()[index + 1..].*);
            }

            pub fn truncateCol(self: Self) Matrix(ComponentType, col_count - 1, row_count) {
                return self.withoutCol(col_count - 1);
            }
        } else struct {};

        pub const withoutCol = MultipleCols.withoutCol;
        pub const truncateCol = MultipleCols.truncateCol;

        pub fn appendRow(self: Self, to_append: Row) Matrix(ComponentType, col_count, row_count + 1) {
            return .fromRows(self.rows() ++ .{ to_append });
        }

        const MultipleRows = if (row_count > 1) struct {
            pub fn withoutRow(self: Self, comptime index: RowIndex) Matrix(ComponentType, col_count, row_count - 1) {
                return .fromRows(self.rows()[0..index].* ++ self.rows()[index + 1..].*);
            }

            pub fn truncateRow(self: Self) Matrix(ComponentType, col_count, row_count - 1) {
                return self.withoutRow(row_count - 1);
            }
        } else struct {};

        pub const withoutRow = MultipleRows.withoutRow;
        pub const truncateRow = MultipleRows.truncateRow;

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (row_count != 1) try writer.writeAll("(");

            inline for (0..row_count) |row_idx| {
                if (col_count != 1) try writer.writeAll("(");
                inline for (0..col_count) |col_idx| {
                    const value = self.at(.{ .col = col_idx, .row = row_idx });
                    try writer.printValue("any", .{}, value, std.options.fmt_max_depth - 1);
                    if (col_idx != col_count - 1) try writer.writeAll(", ");
                }
                if (col_count != 1) try writer.writeAll(")");
                if (row_idx != row_count - 1) try writer.writeAll(", ");
            }

            if (row_count != 1) try writer.writeAll(")");
        }

        const math = if (isNumberType(ComponentType)) struct {
            pub fn mul(self: Self, other: anytype) MatrixProduct(Self, @TypeOf(other)) {
                const Product = MatrixProduct(Self, @TypeOf(other));
                var out = Product.splat(0);
                inline for (0..Product.row_count) |row_idx| {
                    inline for (0..Product.col_count) |col_idx| {
                        inline for (0..col_count) |element_idx| {
                            out.at_mut(.{ .col = col_idx, .row = row_idx }).* +=
                                self.at(.{ .col = element_idx, .row = row_idx }) * other.at(.{ .col = col_idx, .row = element_idx });
                        }
                    }
                }
                return out;
            }

            pub fn scale(self: Self, scalar: ComponentType) Self {
                var out: Self = undefined;
                inline for (0..row_count) |row_idx| {
                    inline for (0..col_count) |col_idx| {
                        out.at_mut(.{ .col = col_idx, .row = row_idx }).* = self.at(.{ .col = col_idx, .row = row_idx }) * scalar;
                    }
                }
                return out;
            }

            pub fn componentMul(self: Self, other: Self) Self {
                var out: Self = undefined;
                inline for (0..row_count) |row_idx| {
                    inline for (0..col_count) |col_idx| {
                        out.at_mut(.{ .col = col_idx, .row = row_idx }).* =
                            self.at(.{ .col = col_idx, .row = row_idx }) * other.at(.{ .col = col_idx, .row = row_idx });
                    }
                }
                return out;
            }

            pub fn componentDiv(self: Self, other: Self) Self {
                var out: Self = undefined;
                inline for (0..row_count) |row_idx| {
                    inline for (0..col_count) |col_idx| {
                        out.at_mut(.{ .col = col_idx, .row = row_idx }).* =
                            self.at(.{ .col = col_idx, .row = row_idx }) / other.at(.{ .col = col_idx, .row = row_idx });
                    }
                }
                return out;
            }

            pub fn componentAdd(self: Self, other: Self) Self {
                var out: Self = undefined;
                inline for (0..row_count) |row_idx| {
                    inline for (0..col_count) |col_idx| {
                        out.at_mut(.{ .col = col_idx, .row = row_idx }).* =
                            self.at(.{ .col = col_idx, .row = row_idx }) + other.at(.{ .col = col_idx, .row = row_idx });
                    }
                }
                return out;
            }

            pub fn componentSub(self: Self, other: Self) Self {
                var out: Self = undefined;
                inline for (0..row_count) |row_idx| {
                    inline for (0..col_count) |col_idx| {
                        out.at_mut(.{ .col = col_idx, .row = row_idx }).* =
                            self.at(.{ .col = col_idx, .row = row_idx }) - other.at(.{ .col = col_idx, .row = row_idx });
                    }
                }
                return out;
            }

            pub fn componentMax(self: Self, other: Self) Self {
                var out: Self = undefined;
                inline for (0..row_count) |row_idx| {
                    inline for (0..col_count) |col_idx| {
                        out.at_mut(.{ .col = col_idx, .row = row_idx }).* =
                            @max(self.at(.{ .col = col_idx, .row = row_idx }), other.at(.{ .col = col_idx, .row = row_idx }));
                    }
                }
                return out;
            }

            pub fn componentMin(self: Self, other: Self) Self {
                var out: Self = undefined;
                inline for (0..row_count) |row_idx| {
                    inline for (0..col_count) |col_idx| {
                        out.at_mut(.{ .col = col_idx, .row = row_idx }).* =
                            @min(self.at(.{ .col = col_idx, .row = row_idx }), other.at(.{ .col = col_idx, .row = row_idx }));
                    }
                }
                return out;
            }

            pub fn componentClamp(self: Self, min: Self, max: Self) Self {
                return self.componentMax(min).componentMin(max);
            }

            const integer = if (isIntegerType(T)) struct {
                pub fn intCast(self: Self, Target: type) Matrix(Target, col_count, row_count) {
                    var out: Matrix(Target, col_count, row_count) = undefined;
                    inline for (0..row_count) |row_idx| {
                        inline for (0..col_count) |col_idx| {
                            out.at_mut(.{ .col = col_idx, .row = row_idx }).* = @intCast(self.at(.{ .col = col_idx, .row = row_idx }));
                        }
                    }
                    return out;
                }

                pub fn floatFromInt(self: Self, Target: type) Matrix(Target, col_count, row_count) {
                    var out: Matrix(Target, col_count, row_count) = undefined;
                    inline for (0..row_count) |row_idx| {
                        inline for (0..col_count) |col_idx| {
                            out.at_mut(.{ .col = col_idx, .row = row_idx }).* = @floatFromInt(self.at(.{ .col = col_idx, .row = row_idx }));
                        }
                    }
                    return out;
                }
            } else struct {};

            pub const intCast = integer.intCast;
            pub const floatFromInt = integer.floatFromInt;

            const float = if (isFloatType(T)) struct {
                pub fn floatCast(self: Self, Target: type) Matrix(Target, col_count, row_count) {
                    var out: Matrix(Target, col_count, row_count) = undefined;
                    inline for (0..row_count) |row_idx| {
                        inline for (0..col_count) |col_idx| {
                            out.at_mut(.{ .col = col_idx, .row = row_idx }).* = @floatCast(self.at(.{ .col = col_idx, .row = row_idx }));
                        }
                    }
                    return out;
                }

                pub fn intFromFloat(self: Self, Target: type) Matrix(Target, col_count, row_count) {
                    var out: Matrix(Target, col_count, row_count) = undefined;
                    inline for (0..row_count) |row_idx| {
                        inline for (0..col_count) |col_idx| {
                            out.at_mut(.{ .col = col_idx, .row = row_idx }).* = @intFromFloat(self.at(.{ .col = col_idx, .row = row_idx }));
                        }
                    }
                    return out;
                }
            } else struct {};

            pub const floatCast = float.floatCast;
            pub const intFromFloat = float.intFromFloat;
        } else struct {};

        pub const mul = math.mul;
        pub const scale = math.scale;
        pub const componentMul = math.componentMul;
        pub const componentDiv = math.componentDiv;
        pub const componentAdd = math.componentAdd;
        pub const componentSub = math.componentSub;
        pub const componentMax = math.componentMax;
        pub const componentMin = math.componentMin;
        pub const componentClamp = math.componentClamp;
        pub const intCast = math.intCast;
        pub const floatFromInt = math.floatFromInt;
        pub const floatCast = math.floatCast;
        pub const intFromFloat = math.intFromFloat;

        const square = if (col_count == row_count) struct {
            pub const identity = Self.diagonal(.{ 1 } ** col_count);

            pub fn diagonal(values: [col_count]ComponentType) Self {
                var out: Self = Self.splat(0);
                inline for (0..col_count) |element_idx| {
                    out.at_mut(.{ .col = element_idx, .row = element_idx }).* = values[element_idx];
                }
                return out;
            }

            const math = if (isNumberType(ComponentType)) struct {
                pub fn determinant(self: Self) ComponentType {
                    return self.cofactor().row(0).dot(self.row(0));
                }

                pub fn cofactor(self: Self) Self {
                    if (comptime col_count == 1) {
                        return Self.identity;
                    } else {
                        var out: Self = undefined;
                        inline for (0..row_count) |row_idx| {
                            inline for (0..col_count) |col_idx| {
                                out.at_mut(.{ .col = col_idx, .row = row_idx }).* = (if ((col_idx + row_idx) % 2 == 0) 1 else -1) * self.withoutCol(col_idx).withoutRow(row_idx).determinant();
                            }
                        }
                        return out;
                    }
                }

                pub fn adjugate(self: Self) Self {
                    return self.cofactor().transpose();
                }

                pub const float = if (isFloatType(ComponentType)) struct {
                    pub fn inverse(self: Self) Self {
                        const det = self.determinant();
                        std.debug.assert(det != 0);
                        return self.adjugate().scale(1 / det);
                    }

                    pub const fromAxisAngle = if (col_count == 3) struct {
                        // TODO: remove this once everything is migrated to rotors
                        pub fn fromAxisAngle(axis: Vec3(ComponentType), angle: ComponentType) Self {
                            const sin, const cos = .{ std.math.sin(angle), std.math.cos(angle) };
                            const x, const y, const z = .{ axis.element(0), axis.element(1), axis.element(2) };

                            return Self.fromRows(.{
                                .new(.{(1 - cos) * x * x + cos, (1 - cos) * x * y - sin * z, (1 - cos) * x * z + sin * y}),
                                .new(.{(1 - cos) * x * y + sin * z, (1 - cos) * y * y + cos, (1 - cos) * y * z - sin * x}),
                                .new(.{(1 - cos) * x * z - sin * y, (1 - cos) * y * z + sin * x, (1 - cos) * z * z + cos}),
                            });
                        }
                    }.fromAxisAngle else unreachable;
                } else struct {};

                pub const inverse = float.inverse;
                pub const fromAxisAngle = float.fromAxisAngle;

            } else struct {};
        } else struct {};

        pub const identity = square.identity;
        pub const diagonal = square.diagonal;
        pub const determinant = square.math.determinant;
        pub const cofactor = square.math.cofactor;
        pub const adjugate = square.math.adjugate;
        pub const inverse = square.math.inverse;
        pub const fromAxisAngle = square.math.fromAxisAngle;

        const vector = if (col_count == 1 or row_count == 1) struct {
            pub fn element_mut(self: *Self, index: std.math.IntFittingRange(0, element_count)) *ComponentType {
                return if (comptime col_count == 1) self.at_mut(.{ .row = index }) else self.at_mut(.{ .col = index });
            }

            pub fn element(self: Self, index: std.math.IntFittingRange(0, element_count)) ComponentType {
                var mut = self;
                return mut.element_mut(index).*;
            }

            pub fn new(array: [element_count]ComponentType) Self {
                return Self.fromArray(array);
            }

            pub fn fromArray(array: [element_count]ComponentType) Self {
                var out: Self = undefined;
                inline for (0..element_count) |element_idx| {
                    out.element_mut(element_idx).* = array[element_idx];
                }
                return out;
            }

            pub fn toArray(self: Self) [element_count]ComponentType {
                var out: [element_count]ComponentType = undefined;
                inline for (0..element_count) |element_idx| {
                    out[element_idx] = self.element(element_idx);
                }
                return out;
            }

            pub fn append(self: Self, value: ComponentType) if (col_count != 1) Matrix(ComponentType, col_count + 1, 1) else Matrix(ComponentType, 1, row_count + 1) {
                return .new(self.toArray() ++ .{ value });
            }

            pub fn truncate(self: Self) if (col_count != 1) Matrix(ComponentType, col_count - 1, 1) else Matrix(ComponentType, 1, row_count - 1) {
                return .new(self.toArray()[0..element_count - 1].*);
            }

            const math = if (isNumberType(ComponentType)) struct {
                pub fn dot(self: Self, other: Self) ComponentType {
                    return (if (comptime col_count == 1) self.transpose().mul(other) else self.mul(other.transpose())).get();
                }

                const PossiblyIntNorm = if (isFloatType(ComponentType) or ComponentType == comptime_int) ComponentType else @Int(.unsigned, @typeInfo(ComponentType).int.bits);

                pub fn normL1(self: Self) PossiblyIntNorm {
                    var out: PossiblyIntNorm = 0;
                    inline for (0..element_count) |element_idx| {
                        out += @abs(self.element(element_idx));
                    }
                    return out;
                }

                pub fn normLInf(self: Self) PossiblyIntNorm {
                    var out: PossiblyIntNorm = 0;
                    inline for (0..element_count) |element_idx| {
                        out = @max(out, @abs(self.element(element_idx)));
                    }
                    return out;
                }

                const float = if (isFloatType(ComponentType)) struct {
                    pub fn normL2(self: Self) ComponentType {
                        return std.math.sqrt(self.dot(self));
                    }

                    pub fn unit(self: Self) Self {
                        return self.scale(@as(ComponentType, 1) / self.normL2());
                    }
                } else struct {};

                pub const normL2 = float.normL2;
                pub const unit = float.unit;

                pub const wedge = if (element_count > 1) struct {
                    // technically this returns a bivector rather than a vector,
                    // but currently there's no way to destinguish these
                    const Bivector = if (col_count != 1) Matrix(ComponentType, col_count * (col_count - 1) / 2, 1) else Matrix(ComponentType, 1, row_count * (row_count - 1) / 2);
                    pub fn wedge(self: Self, other: Self) Bivector {
                        var out: Bivector = undefined;
                        comptime var out_idx = 0;
                        inline for (0..element_count) |j| {
                            inline for (0..j) |i| {
                                out.element_mut(out_idx).* = self.element(i) * other.element(j) - self.element(j) * other.element(i);
                                out_idx += 1;
                            }
                        }
                        return out;
                    }
                }.wedge else struct {};

                pub const cross = if (element_count == 3) struct {
                    pub fn cross(self: Self, other: Self) Self {
                        const x = self.element(1) * other.element(2) - other.element(1) * self.element(2);
                        const y = self.element(2) * other.element(0) - other.element(2) * self.element(0);
                        const z = self.element(0) * other.element(1) - other.element(0) * self.element(1);
                        return Self.new(.{ x, y, z });
                    }
                }.cross else struct {};
            } else struct {};
        } else struct {};

        pub const element_mut = vector.element_mut;
        pub const element = vector.element;
        pub const new = vector.new;
        pub const fromArray = vector.fromArray;
        pub const toArray = vector.toArray;
        pub const append = vector.append;
        pub const truncate = vector.truncate;
        pub const dot = vector.math.dot;
        pub const normL1 = vector.math.normL1;
        pub const normLInf = vector.math.normLInf;
        pub const normL2 = vector.math.normL2;
        pub const unit = vector.math.unit;
        pub const wedge = vector.math.wedge;
        pub const cross = vector.math.cross;

        pub const get = if (col_count == 1 and row_count == 1) struct {
            pub fn get(self: Self) ComponentType {
                return self.at(.{});
            }
        }.get else struct {};
    };
}

pub fn VecN(comptime T: type, comptime n: comptime_int) type {
    return Matrix(T, 1, n);
}

pub fn Vec2(comptime T: type) type {
    return VecN(T, 2);
}

pub fn Vec3(comptime T: type) type {
    return VecN(T, 3);
}

pub fn Vec4(comptime T: type) type {
    return VecN(T, 4);
}

pub fn MatN(comptime T: type, comptime n: comptime_int) type {
    return Matrix(T, n, n);
}

pub fn Mat2(comptime T: type) type {
    return MatN(T, 2);
}

pub fn Mat3(comptime T: type) type {
    return MatN(T, 3);
}

pub fn Mat4(comptime T: type) type {
    return MatN(T, 4);
}

pub fn Mat4x3(comptime T: type) type {
    return Matrix(T, 4, 3);
}

// this generalized well to N dimensions, but in order to do that ergonomically I'd need to
// have proper support for n-vectors and multivectors and even subspaces and I don't want to
// do that right now
// WARNING: this ended up never going into use so it hasn't been properly tested
pub fn Rotor3(comptime T: type) type {
    if (!isNumberType(T)) @compileError("Rotor inner type must be a number type, but is " ++ @typeName(T));

    return extern struct {
        bivector: Vec3(T),
        scalar: T,

        const Self = @This();

        pub const identity = Self.new(Vec3(T).new(.{ 0, 0, 0 }), 1);

        pub fn new(bivector: Vec3(T), scalar: T) Self {
            return Self {
                .bivector = bivector,
                .scalar = scalar,
            };
        }

        pub fn mul(self: Self, other: Self) Self {
            return Self.new(
                other.bivector.scale(self.scalar).componentAdd(self.bivector.scale(other.scalar)).componentAdd(Vec3(T).new(.{
                    self.bivector.element(2) * other.bivector.element(1) - self.bivector.element(1) * other.bivector.element(2),
                    - self.bivector.element(2) * other.bivector.element(0) + self.bivector.element(0) * other.bivector.element(2),
                    self.bivector.element(1) * other.bivector.element(0) - self.bivector.element(0) * other.bivector.element(1),
                })),
                self.scalar * other.scalar - self.bivector.dot(other.bivector)
            );
        }

        pub fn reverse(self: Self) Self {
            return Self.new(self.bivector.scale(-1), self.scalar);
        }

        pub fn rotateVector(self: Self, v: Vec3(T)) Vec3(T) {
            const q = v.scale(self.scalar).componentAdd(Vec3(T).new(.{
                  v.element(1) * self.bivector.element(0) + v.element(2) * self.bivector.element(1),
                - v.element(0) * self.bivector.element(0) + v.element(2) * self.bivector.element(2),
                - v.element(0) * self.bivector.element(1) - v.element(1) * self.bivector.element(2),
            }));

            const trivector = v.element(0) * self.bivector.element(2) - v.element(1) * self.bivector.element(1) + v.element(2) * self.bivector.element(0);

            const r = q.scale(self.scalar).componentAdd(Vec3(T).new(.{
                  q.element(1) * self.bivector.element(0) + q.element(2) * self.bivector.element(1) + trivector * self.bivector.element(2),
                - q.element(0) * self.bivector.element(0) - trivector * self.bivector.element(1) + q.element(2) * self.bivector.element(2),
                  trivector * self.bivector.element(0) - q.element(0) * self.bivector.element(1) - q.element(1) * self.bivector.element(2),
            }));

            return r;
        }

        pub fn rotateRotor(self: Self, other: Self) Self {
            return self.mul(other).mul(self.reverse());
        }

        const float = if (isFloatType(T)) struct {
            pub fn norm(self: Self) T {
                return std.math.sqrt(self.scalar * self.scalar + self.bivector.dot(self.bivector));
            }

            pub fn unit(self: Self) Self {
                return Self.new(self.bivector.scale(@as(T, 1) / self.norm()), self.scalar / self.norm());
            }

            // plane must be normalized
            pub fn fromPlaneAngle(plane: Vec3(T), angle: T) Self {
                const sin = std.math.sin(angle / 2.0);
                const cos = std.math.cos(angle / 2.0);
                return Self.new(plane.scale(-sin), cos).unit();
            }

            pub fn fromMatrix(m: Mat3(T)) Self {
                std.debug.assert(std.math.approxEqRel(T, m.determinant(), 1, std.math.sqrt(std.math.floatEps(f32))));

                var bivector: Vec3(T) = .splat(0);
                var scalar: T = 1;

                inline for (0..Mat3(T).col_count) |col_idx| {
                    bivector = bivector.componentAdd(Mat3(T).identity.col(col_idx).wedge(m.col(col_idx)));
                    scalar += Mat3(T).identity.col(col_idx).dot(m.col(col_idx));
                }

                return Self.new(bivector, scalar).unit();
            }

            pub fn fromXYZ(v: Vec3(T)) Self {
                return Self.fromPlaneAngle(Vec3(T).new(.{1, 0, 0}).wedge(Vec3(T).new(.{0, 1, 0})), v.element(2))
                    .mul(Self.fromPlaneAngle(Vec3(T).new(.{1, 0, 0}).wedge(Vec3(T).new(.{0, 0, 1})), v.element(1)))
                    .mul(Self.fromPlaneAngle(Vec3(T).new(.{0, 1, 0}).wedge(Vec3(T).new(.{0, 0, 1})), v.element(0)));
            }
        } else struct {};

        const norm = float.norm;
        const unit = float.unit;
        const fromPlaneAngle = float.fromPlaneAngle;
        const fromMatrix = float.fromMatrix;
        const fromXYZ = float.fromXYZ;

        pub fn toMatrix(self: Self) Mat3(T) {
            return Mat3(T).fromCols(.{
                self.rotateVector(Mat3(T).identity.col(0)),
                self.rotateVector(Mat3(T).identity.col(1)),
                self.rotateVector(Mat3(T).identity.col(2)),
            }).transpose();
        }
    };
}

test "vector algebra" {
    const v0 = Vec3(i32).new(.{ 4, 1, 3 });
    const v1 = Vec3(i32).new(.{ 2, 9, 8 });
    const v2 = Vec3(i32).new(.{ 7, 0, 1 });

    try std.testing.expectEqual(v0.componentAdd(v1), Vec3(i32).new(.{ 6, 10, 11 }));
    try std.testing.expectEqual(v1.componentAdd(v2), Vec3(i32).new(.{ 9, 9, 9 }));
    try std.testing.expectEqual(v0.componentAdd(v2), Vec3(i32).new(.{ 11, 1, 4 }));

    try std.testing.expectEqual(v0.componentSub(v1), Vec3(i32).new(.{ 2, -8, -5 }));
    try std.testing.expectEqual(v1.componentSub(v2), Vec3(i32).new(.{ -5, 9, 7 }));
    try std.testing.expectEqual(v0.componentSub(v2), v2.componentSub(v0).scale(-1));

    try std.testing.expectEqual(v0.componentMul(v1), Vec3(i32).new(.{ 8, 9, 24 }));
    try std.testing.expectEqual(v1.componentMul(v2), Vec3(i32).new(.{ 14, 0, 8 }));
    try std.testing.expectEqual(v0.componentMul(v2), Vec3(i32).new(.{ 28, 0, 3 }));

    try std.testing.expectEqual(v0.scale(0), Vec3(i32).splat(0));
    try std.testing.expectEqual(v0.scale(1), v0);
    try std.testing.expectEqual(v0.scale(2), v0.componentAdd(v0));
}

test "vector products" {
    const v0 = Vec3(i32).new(.{ 8, 5, 9 });
    const v1 = Vec3(i32).new(.{ 0,-4, 1 });
    const v2 = Vec3(i32).new(.{ 1, 0, 2 });

    // symmetric
    try std.testing.expectEqual(v0.dot(v1), v1.dot(v0));
    try std.testing.expectEqual(v1.dot(v2), v2.dot(v1));
    try std.testing.expectEqual(v0.dot(v2), v2.dot(v0));

    try std.testing.expectEqual(v0.dot(v1), -11);
    try std.testing.expectEqual(v1.dot(v2), 2);
    try std.testing.expectEqual(v0.dot(v2), 26);

    // antisymmetric
    try std.testing.expectEqual(v0.cross(v1), v1.cross(v0).scale(-1));
    try std.testing.expectEqual(v1.cross(v2), v2.cross(v1).scale(-1));
    try std.testing.expectEqual(v0.cross(v2), v2.cross(v0).scale(-1));

    try std.testing.expectEqual(v0.cross(v1), Vec3(i32).new(.{ 41, -8, -32 }));
    try std.testing.expectEqual(v1.cross(v2), Vec3(i32).new(.{ -8, 1, 4 }));
    try std.testing.expectEqual(v0.cross(v2), Vec3(i32).new(.{  10, -7, -5 }));

    // antisymmetric
    try std.testing.expectEqual(v0.wedge(v1), v1.wedge(v0).scale(-1));
    try std.testing.expectEqual(v1.wedge(v2), v2.wedge(v1).scale(-1));
    try std.testing.expectEqual(v0.wedge(v2), v2.wedge(v0).scale(-1));

    try std.testing.expectEqual(Vec2(i32).new(.{ 2, 3 }).wedge(Vec2(i32).new(.{ -1, 4 })), VecN(i32, 1).new(.{ 11 }));
    try std.testing.expectEqual(Vec3(i32).new(.{ 1, 3, -2 }).wedge(Vec3(i32).new(.{ 5, 2, 8 })), Vec3(i32).new(.{ -13, 18, 28 }));
    try std.testing.expectEqual(Vec4(i32).new(.{ 2, 3, 4, 5 }).wedge(Vec4(i32).new(.{ 6, 7, 8, 9 })), VecN(i32, 6).new(.{ -4, -8, -4, -12, -8, -4 }));
}

test "vector norms" {
    const v0 = Vec3(i32).new(.{ 3, 4, 5 });
    const v1 = Vec3(i32).new(.{ 0,-4, -2 });
    const v2 = Vec3(i32).new(.{ 0, 0, 0 });

    try std.testing.expectEqual(v0.normL1(), 12);
    try std.testing.expectEqual(v1.normL1(), 6);
    try std.testing.expectEqual(v2.normL1(), 0);

    try std.testing.expectEqual(v0.normLInf(), 5);
    try std.testing.expectEqual(v1.normLInf(), 4);
    try std.testing.expectEqual(v2.normLInf(), 0);

    try std.testing.expectApproxEqRel(v0.floatFromInt(f64).normL2(), 5.0 * std.math.sqrt(2.0), std.math.sqrt(std.math.floatEps(f64)));
    try std.testing.expectApproxEqRel(v1.floatFromInt(f64).normL2(), 2.0 * std.math.sqrt(5.0), std.math.sqrt(std.math.floatEps(f64)));
    try std.testing.expectEqual(v2.floatFromInt(f64).normL2(), 0.0);
}

test "matrix products" {
    const m0 = Mat3(i32).fromRows(.{
        .new(.{ 3, -2, 5 }),
        .new(.{ 3, 0, 7 }),
        .new(.{ 1, 4, -9 }),
    });
    const m1 = Mat3(i32).fromRows(.{
        .new(.{ 9, 2, 5 }),
        .new(.{ 3, 3, 1 }),
        .new(.{ 8, 4, 8 }),
    });

    try std.testing.expectEqual(m0.mul(m1), Mat3(i32).fromRows(.{
        .new(.{ 61, 20, 53 }),
        .new(.{ 83, 34, 71 }),
        .new(.{ -51, -22, -63 }),
    }));

    try std.testing.expectEqual(m1.mul(m0), Mat3(i32).fromRows(.{
        .new(.{ 38, 2, 14 }),
        .new(.{ 19, -2, 27 }),
        .new(.{ 44, 16, -4 }),
    }));
}

test "rotor" {
    const v0 = Vec3(i32).new(.{ 8, 5, 9 });
    const v1 = Vec3(i32).new(.{ 0,-4, 1 });
    const v2 = Vec3(i32).new(.{ 1, 0, 2 });

    try std.testing.expectEqual(v0, Rotor3(i32).identity.rotateVector(v0));
    try std.testing.expectEqual(v1, Rotor3(i32).identity.rotateVector(v1));
    try std.testing.expectEqual(v2, Rotor3(i32).identity.rotateVector(v2));

    try std.testing.expectEqual(Rotor3(i32).identity, Rotor3(i32).identity.rotateRotor(Rotor3(i32).identity));

    const xy_plane = Vec3(f64).new(.{ 1, 0, 0 }).wedge(Vec3(f64).new(.{ 0, 1, 0}));
    const x_to_neg_x = Rotor3(f64).fromPlaneAngle(xy_plane, std.math.pi);
    const x_to_y = Rotor3(f64).fromPlaneAngle(xy_plane, std.math.pi / 2.0);

    const x = Vec3(f64).new(.{ 1, 0, 0 });
    const neg_x = x.scale(-1);

    const y = Vec3(f64).new(.{ 0, 1, 0 });
    const neg_y = y.scale(-1);

    inline for (0..Vec3(f64).element_count) |i| {
        try std.testing.expectApproxEqAbs(neg_x.element(i), x_to_neg_x.rotateVector(x).element(i), 2.0 * std.math.floatEps(f64));
    }

    inline for (0..Vec3(f64).element_count) |i| {
        try std.testing.expectApproxEqAbs(neg_y.element(i), x_to_neg_x.rotateVector(y).element(i), 2.0 * std.math.floatEps(f64));
    }

    inline for (0..Vec3(f64).element_count) |i| {
        try std.testing.expectApproxEqAbs(y.element(i), x_to_y.rotateVector(x).element(i), 2.0 * std.math.floatEps(f64));
    }

    inline for (0..Vec3(f64).element_count) |i| {
        try std.testing.expectApproxEqAbs(neg_x.element(i), x_to_y.rotateVector(y).element(i), 2.0 * std.math.floatEps(f64));
    }

    const x_to_y_reconstructed = Rotor3(f64).fromMatrix(x_to_y.toMatrix());
    try std.testing.expectApproxEqAbs(x_to_y.scalar, x_to_y_reconstructed.scalar, 2.0 * std.math.floatEps(f64));
    inline for (0..Vec3(f64).element_count) |i| {
        try std.testing.expectApproxEqAbs(x_to_y.bivector.element(i), x_to_y_reconstructed.bivector.element(i), 2.0 * std.math.floatEps(f64));
    }
}
