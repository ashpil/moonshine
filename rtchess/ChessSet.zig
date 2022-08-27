const std = @import("std");

const VulkanContext = @import("engine").rendersystem.VulkanContext;
const VkAllocator = @import("engine").rendersystem.Allocator;
const Commands = @import("engine").rendersystem.Commands;
const Scene = @import("engine").rendersystem.Scene;
const descriptor = @import("engine").rendersystem.descriptor;
const SceneDescriptorLayout = descriptor.SceneDescriptorLayout;
const BackgroundDescriptorLayout = descriptor.BackgroundDescriptorLayout;
const vector = @import("engine").vector;
const Mat3x4 = vector.Mat3x4(f32);
const F32x3 = vector.Vec3(f32);
const Coord = @import("./coord.zig").Coord;

pub const Material = Scene.Material;

pub const Piece = struct {
    black_material_index: u32,
    white_material_index: u32,
    model_path: []const u8,
};

pub const Board = struct {
    material_index: u32,
    model_path: []const u8,
};

pub const SetInfo = struct {
    board: Board,

    pawn: Piece,
    rook: Piece,
    knight: Piece,
    bishop: Piece,
    king: Piece,
    queen: Piece,
};

scene: Scene,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, comptime materials: []const Material, comptime background_dir: []const u8, comptime chess_set: SetInfo, descriptor_layout: *const SceneDescriptorLayout, background_descriptor_layout: *const BackgroundDescriptorLayout) !Self {

    const instance_count = 33;

    var instances = Scene.Instances {};
    try instances.ensureTotalCapacity(allocator, instance_count);

    // board
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Mat3x4.identity,
            .mesh_index = 0,
        },
        .material_index = 0,
    });

    const black_rotation = Mat3x4.from_rotation(F32x3.new(0.0, 1.0, 0.0), std.math.pi);

    // pawns
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.h2.toTransform(),
            .mesh_index = 1,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.g2.toTransform(),
            .mesh_index = 1,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.f2.toTransform(),
            .mesh_index = 1,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.e2.toTransform(),
            .mesh_index = 1,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.d2.toTransform(),
            .mesh_index = 1,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.c2.toTransform(),
            .mesh_index = 1,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.b2.toTransform(),
            .mesh_index = 1,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.a2.toTransform(),
            .mesh_index = 1,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.h7.toTransform().mul(black_rotation),
            .mesh_index = 1,
        },
        .material_index = 2,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.g7.toTransform().mul(black_rotation),
            .mesh_index = 1,
        },
        .material_index = 2,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.f7.toTransform().mul(black_rotation),
            .mesh_index = 1,
        },
        .material_index = 2,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.e7.toTransform().mul(black_rotation),
            .mesh_index = 1,
        },
        .material_index = 2,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.d7.toTransform().mul(black_rotation),
            .mesh_index = 1,
        },
        .material_index = 2,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.c7.toTransform().mul(black_rotation),
            .mesh_index = 1,
        },
        .material_index = 2,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.b7.toTransform().mul(black_rotation),
            .mesh_index = 1,
        },
        .material_index = 2,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.a7.toTransform().mul(black_rotation),
            .mesh_index = 1,
        },
        .material_index = 2,
    });

    // rooks
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.a1.toTransform(),
            .mesh_index = 2,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.h1.toTransform(),
            .mesh_index = 2,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.a8.toTransform().mul(black_rotation),
            .mesh_index = 2,
        },
        .material_index = 2,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.h8.toTransform().mul(black_rotation),
            .mesh_index = 2,
        },
        .material_index = 2,
    });

    // knights
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.b1.toTransform(),
            .mesh_index = 3,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.g1.toTransform(),
            .mesh_index = 3,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.b8.toTransform().mul(black_rotation),
            .mesh_index = 3,
        },
        .material_index = 2,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.g8.toTransform().mul(black_rotation),
            .mesh_index = 3,
        },
        .material_index = 2,
    });

    // bishops
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.c1.toTransform(),
            .mesh_index = 4,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.f1.toTransform(),
            .mesh_index = 4,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.c8.toTransform().mul(black_rotation),
            .mesh_index = 4,
        },
        .material_index = 2,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.f8.toTransform().mul(black_rotation),
            .mesh_index = 4,
        },
        .material_index = 2,
    });

    // kings
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.e1.toTransform(),
            .mesh_index = 5,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.e8.toTransform().mul(black_rotation),
            .mesh_index = 5,
        },
        .material_index = 2,
    });

    // queens
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.d1.toTransform(),
            .mesh_index = 6,
        },
        .material_index = 1,
    });
    instances.appendAssumeCapacity(.{
        .mesh_info = .{
            .transform = Coord.d8.toTransform().mul(black_rotation),
            .mesh_index = 6,
        },
        .material_index = 2,
    });

    const mesh_filepaths = [_][]const u8 {
        chess_set.board.model_path,
        chess_set.pawn.model_path,
        chess_set.rook.model_path,
        chess_set.knight.model_path,
        chess_set.bishop.model_path,
        chess_set.king.model_path,
        chess_set.queen.model_path,
    };

    const scene = try Scene.create(vc, vk_allocator, allocator, commands, materials, background_dir, &mesh_filepaths, instances, descriptor_layout, background_descriptor_layout);

    return Self {
        .scene = scene,
    };
}

// todo: make this more high level
pub fn move(self: *Self, index: u32, new_transform: Mat3x4) void {
    self.scene.updateTransform(index, new_transform);
}

pub fn changeVisibility(self: *Self, index: u32, visible: bool) void {
    self.scene.updateVisibility(index, visible);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.scene.destroy(vc, allocator);
}
