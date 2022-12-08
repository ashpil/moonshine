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
    black_material_idx: u32,
    white_material_idx: u32,
    model_path: []const u8,
};

pub const Board = struct {
    material_idx: u32,
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

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, materials: []const Material, background_dir: []const u8, chess_set: SetInfo, descriptor_layout: *const SceneDescriptorLayout, background_descriptor_layout: *const BackgroundDescriptorLayout) !Self {

    const models = [_]Scene.Model {
        .{ // board
            .mesh_idxs = &.{ 0 },
        },
        .{ // pawn
            .mesh_idxs = &.{ 1 },
        },
        .{ // rook
            .mesh_idxs = &.{ 2 },
        },
        .{ // knight
            .mesh_idxs = &.{ 3 },
        },
        .{ // bishop
            .mesh_idxs = &.{ 4 },
        },
        .{ // king
            .mesh_idxs = &.{ 5 },
        },
        .{ // queen
            .mesh_idxs = &.{ 6 },
        },
    };

    const instance_count = 33;

    var instances = Scene.Instances {};
    try instances.ensureTotalCapacity(allocator, instance_count);
    defer instances.deinit(allocator);

    // board
    instances.appendAssumeCapacity(.{
        .transform = Mat3x4.identity,
        .model_idx = 0,
        .material_idxs = &.{ 0 },
    });

    const black_rotation = Mat3x4.from_rotation(F32x3.new(0.0, 1.0, 0.0), std.math.pi);

    // pawns
    {
        // white
        {
            instances.appendAssumeCapacity(.{
                .transform = Coord.h2.toTransform(),
                .model_idx = 1,
                .material_idxs = &.{ 1 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.g2.toTransform(),
                .model_idx = 1,
                .material_idxs = &.{ 1 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.f2.toTransform(),
                .model_idx = 1,
                .material_idxs = &.{ 1 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.e2.toTransform(),
                .model_idx = 1,
                .material_idxs = &.{ 1 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.d2.toTransform(),
                .model_idx = 1,
                .material_idxs = &.{ 1 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.c2.toTransform(),
                .model_idx = 1,
                .material_idxs = &.{ 1 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.b2.toTransform(),
                .model_idx = 1,
                .material_idxs = &.{ 1 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.a2.toTransform(),
                .model_idx = 1,
                .material_idxs = &.{ 1 },
            });
        }
        // black
        {
            instances.appendAssumeCapacity(.{
                .transform = Coord.h7.toTransform().mul(black_rotation),
                .model_idx = 1,
                .material_idxs = &.{ 2 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.g7.toTransform().mul(black_rotation),
                .model_idx = 1,
                .material_idxs = &.{ 2 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.f7.toTransform().mul(black_rotation),
                .model_idx = 1,
                .material_idxs = &.{ 2 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.e7.toTransform().mul(black_rotation),
                .model_idx = 1,
                .material_idxs = &.{ 2 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.d7.toTransform().mul(black_rotation),
                .model_idx = 1,
                .material_idxs = &.{ 2 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.c7.toTransform().mul(black_rotation),
                .model_idx = 1,
                .material_idxs = &.{ 2 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.b7.toTransform().mul(black_rotation),
                .model_idx = 1,
                .material_idxs = &.{ 2 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.a7.toTransform().mul(black_rotation),
                .model_idx = 1,
                .material_idxs = &.{ 2 },
            });
        }
    }

    // rooks
    {
        // white
        {
            instances.appendAssumeCapacity(.{
                .transform = Coord.a1.toTransform(),
                .model_idx = 2,
                .material_idxs = &.{ 1 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.h1.toTransform(),
                .model_idx = 2,
                .material_idxs = &.{ 1 },
            });
        }
        // black
        {
            instances.appendAssumeCapacity(.{
                .transform = Coord.a8.toTransform().mul(black_rotation),
                .model_idx = 2,
                .material_idxs = &.{ 2 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.h8.toTransform().mul(black_rotation),
                .model_idx = 2,
                .material_idxs = &.{ 2 },
            });
        }
    }

    // knights
    {
        // white
        {
            instances.appendAssumeCapacity(.{
                .transform = Coord.b1.toTransform(),
                .model_idx = 3,
                .material_idxs = &.{ 1 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.g1.toTransform(),
                .model_idx = 3,
                .material_idxs = &.{ 1 },
            });
        }
        // black
        {
            instances.appendAssumeCapacity(.{
                .transform = Coord.b8.toTransform().mul(black_rotation),
                .model_idx = 3,
                .material_idxs = &.{ 2 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.g8.toTransform().mul(black_rotation),
                .model_idx = 3,
                .material_idxs = &.{ 2 },
            });
        }
    }

    // bishops
    {
        // white
        {
            instances.appendAssumeCapacity(.{
                .transform = Coord.c1.toTransform(),
                .model_idx = 4,
                .material_idxs = &.{ 1 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.f1.toTransform(),
                .model_idx = 4,
                .material_idxs = &.{ 1 },
            });
        }
        // black
        {
            instances.appendAssumeCapacity(.{
                .transform = Coord.c8.toTransform().mul(black_rotation),
                .model_idx = 4,
                .material_idxs = &.{ 2 },
            });
            instances.appendAssumeCapacity(.{
                .transform = Coord.f8.toTransform().mul(black_rotation),
                .model_idx = 4,
                .material_idxs = &.{ 2 },
            });
        }
    }

    // kings
    {
        // white
        instances.appendAssumeCapacity(.{
            .transform = Coord.e1.toTransform(),
            .model_idx = 5,
            .material_idxs = &.{ 1 },
        });
        // black
        instances.appendAssumeCapacity(.{
            .transform = Coord.e8.toTransform().mul(black_rotation),
            .model_idx = 5,
            .material_idxs = &.{ 2 },
        });
    }

    // queens
    {
        // white
        instances.appendAssumeCapacity(.{
            .transform = Coord.d1.toTransform(),
            .model_idx = 6,
            .material_idxs = &.{ 1 },
        });
        // black
        instances.appendAssumeCapacity(.{
            .transform = Coord.d8.toTransform().mul(black_rotation),
            .model_idx = 6,
            .material_idxs = &.{ 2 },
        });
    }

    const mesh_filepaths = [_][]const u8 {
        chess_set.board.model_path,
        chess_set.pawn.model_path,
        chess_set.rook.model_path,
        chess_set.knight.model_path,
        chess_set.bishop.model_path,
        chess_set.king.model_path,
        chess_set.queen.model_path,
    };

    const scene = try Scene.create(vc, vk_allocator, allocator, commands, materials, background_dir, &mesh_filepaths, instances, &models, descriptor_layout, background_descriptor_layout);

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
