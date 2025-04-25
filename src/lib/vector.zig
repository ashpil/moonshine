const std = @import("std");
const math = std.math;

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

        pub const ColIndex = math.IntFittingRange(0, col_count);
        pub const RowIndex = math.IntFittingRange(0, row_count);
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
            std.debug.assert(index.col < col_count);
            std.debug.assert(index.row < row_count);
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

        pub fn col(self: Self, index: math.IntFittingRange(0, col_count)) Col {
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

        pub fn row(self: Self, index: math.IntFittingRange(0, row_count)) Row {
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

        pub fn splat(element: ComponentType) Self {
            var out: Self = undefined;
            inline for (0..col_count) |col_idx| {
                inline for (0..row_count) |row_idx| {
                    out.at_mut(.{ .col = col_idx, .row = row_idx }).* = element;
                }
            }
            return out;
        }

        pub fn appendCol(self: Self, to_append: Col) Matrix(ComponentType, col_count + 1, row_count) {
            return .fromCols(self.cols() ++ .{ to_append });
        }

        pub usingnamespace if (col_count > 1) struct {
            pub fn withoutCol(self: Self, comptime index: ColIndex) Matrix(ComponentType, col_count - 1, row_count) {
                return .fromCols(self.cols()[0..index].* ++ self.cols()[index + 1..].*);
            }

            pub fn truncateCol(self: Self) Matrix(ComponentType, col_count - 1, row_count) {
                return self.withoutCol(col_count - 1);
            }
        } else struct {};

        pub fn appendRow(self: Self, to_append: Row) Matrix(ComponentType, col_count, row_count + 1) {
            return .fromRows(self.rows() ++ .{ to_append });
        }

        pub usingnamespace if (row_count > 1) struct {
            pub fn withoutRow(self: Self, comptime index: RowIndex) Matrix(ComponentType, col_count, row_count - 1) {
                return .fromRows(self.rows()[0..index].* ++ self.rows()[index + 1..].*);
            }

            pub fn truncateRow(self: Self) Matrix(ComponentType, col_count, row_count - 1) {
                return self.withoutRow(row_count - 1);
            }
        } else struct {};

        // math methods
        pub usingnamespace if (isNumberType(ComponentType)) struct {
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
        } else struct {};

        // square matrix methods
        pub usingnamespace if (col_count == row_count) struct {
            pub const identity = Self.diagonal(.{ 1 } ** col_count);

            pub fn diagonal(values: [col_count]ComponentType) Self {
                var out: Self = Self.splat(0);
                inline for (0..col_count) |element_idx| {
                    out.at_mut(.{ .col = element_idx, .row = element_idx }).* = values[element_idx];
                }
                return out;
            }

            // square matrix math methods
            pub usingnamespace if (isNumberType(ComponentType)) struct {
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

                pub usingnamespace if (isFloatType(ComponentType)) struct {
                    pub fn inverse(self: Self) Self {
                        const det = self.determinant();
                        std.debug.assert(det != 0);
                        return self.adjugate().scale(1 / det);
                    }
                } else struct {};
            } else struct {};

            pub usingnamespace if (col_count == 3 and isFloatType(ComponentType)) struct {
                // TODO: this should be a member function of a rotor/quaternion, not of a matrix
                pub fn fromAxisAngle(axis: Vec3(ComponentType), angle: ComponentType) Self {
                    const sin, const cos = .{ math.sin(angle), math.cos(angle) };
                    const x, const y, const z = .{ axis.element(0), axis.element(1), axis.element(2) };

                    return Self.fromRows(.{
                        .new(.{(1 - cos) * x * x + cos, (1 - cos) * x * y - sin * z, (1 - cos) * x * z + sin * y}),
                        .new(.{(1 - cos) * x * y + sin * z, (1 - cos) * y * y + cos, (1 - cos) * y * z - sin * x}),
                        .new(.{(1 - cos) * x * z - sin * y, (1 - cos) * y * z + sin * x, (1 - cos) * z * z + cos}),
                    });
                }
            } else struct {};
        } else struct {};

        // vector methods
        pub usingnamespace if (col_count == 1 or row_count == 1) struct {
            pub fn element_mut(self: *Self, index: math.IntFittingRange(0, element_count)) *ComponentType {
                return if (comptime col_count == 1) self.at_mut(.{ .row = index }) else self.at_mut(.{ .col = index });
            }

            pub fn element(self: Self, index: math.IntFittingRange(0, element_count)) ComponentType {
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

            // vector math methods
            pub usingnamespace if (isNumberType(ComponentType)) struct {
                pub fn dot(self: Self, other: Self) ComponentType {
                    return (if (comptime col_count == 1) self.transpose().mul(other) else self.mul(other.transpose())).get();
                }

                pub fn normL1(self: Self) ComponentType {
                    var out = 0;
                    inline for (0..element_count) |element_idx| {
                        out += @abs(self.element(element_idx));
                    }
                    return out;
                }

                pub fn normLinf(self: Self) ComponentType {
                    var out = 0;
                    inline for (0..element_count) |element_idx| {
                        out = @max(out, @abs(self.element(element_idx)));
                    }
                    return out;
                }

                pub usingnamespace if (isFloatType(ComponentType)) struct {
                    pub fn normL2(self: Self) ComponentType {
                        return math.sqrt(self.dot(self));
                    }

                    pub fn unit(self: Self) Self {
                        return self.scale(@as(ComponentType, 1) / self.normL2());
                    }
                } else struct {};

                // TODO: generalize to full wedge product,
                // don't want to specialize on three dimensions
                pub usingnamespace if (element_count == 3) struct {
                    pub fn cross(self: Self, other: Self) Self {
                        const x = self.element(1) * other.element(2) - other.element(1) * self.element(2);
                        const y = self.element(2) * other.element(0) - other.element(2) * self.element(0);
                        const z = self.element(0) * other.element(1) - other.element(0) * self.element(1);
                        return Self.new(.{ x, y, z });
                    }
                } else struct {};
            } else struct {};
        } else struct {};


        pub usingnamespace if (col_count == 1 and row_count == 1) struct {
            pub fn get(self: Self) ComponentType {
                return self.at(.{});
            }
        } else struct {};
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
