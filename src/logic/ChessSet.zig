const std = @import("std");

const VulkanContext = @import("../renderer/VulkanContext.zig");
const TransferCommands = @import("../renderer/commands.zig").ComputeCommands;
const Scene = @import("../renderer/Scene.zig");
const zug = @import("../utils/zug.zig");
const Mat3x4 = zug.Mat3x4(f32);
const Vec3 = zug.Vec3(f32);
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

pub fn create(vc: *const VulkanContext, commands: *TransferCommands, comptime materials: []const Material, comptime background_filepath: []const u8, comptime chess_set: SetInfo, allocator: *std.mem.Allocator) !Self {

    var board_instance = Scene.Instances {};
    defer board_instance.deinit(allocator);
    try board_instance.ensureTotalCapacity(allocator, 1);
    board_instance.appendAssumeCapacity(.{
        .initial_transform = Mat3x4.identity,
        .material_index = 0,
    });

    const black_rotation = Mat3x4.from_rotation(Vec3.new(0.0, 1.0, 0.0), std.math.pi);

    var pawn_instance = Scene.Instances {};
    defer pawn_instance.deinit(allocator);
    try pawn_instance.ensureTotalCapacity(allocator, 16);
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.h2.toTransform(),
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.g2.toTransform(),
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.f2.toTransform(),
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.e2.toTransform(),
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.d2.toTransform(),
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.c2.toTransform(),
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.b2.toTransform(),
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.a2.toTransform(),
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.h7.toTransform().mul(black_rotation),
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.g7.toTransform().mul(black_rotation),
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.f7.toTransform().mul(black_rotation),
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.e7.toTransform().mul(black_rotation),
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.d7.toTransform().mul(black_rotation),
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.c7.toTransform().mul(black_rotation),
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.b7.toTransform().mul(black_rotation),
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.a7.toTransform().mul(black_rotation),
        .material_index = 2,
    });

    var rook_instance = Scene.Instances {};
    defer rook_instance.deinit(allocator);
    try rook_instance.ensureTotalCapacity(allocator, 4);
    rook_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.a1.toTransform(),
        .material_index = 1,
    });
    rook_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.h1.toTransform(),
        .material_index = 1,
    });
    rook_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.a8.toTransform().mul(black_rotation),
        .material_index = 2,
    });
    rook_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.h8.toTransform().mul(black_rotation),
        .material_index = 2,
    });

    var knight_instance = Scene.Instances {};
    defer knight_instance.deinit(allocator);
    try knight_instance.ensureTotalCapacity(allocator, 4);
    knight_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.b1.toTransform(),
        .material_index = 1,
    });
    knight_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.g1.toTransform(),
        .material_index = 1,
    });
    knight_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.b8.toTransform().mul(black_rotation),
        .material_index = 2,
    });
    knight_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.g8.toTransform().mul(black_rotation),
        .material_index = 2,
    });

    var bishop_instance = Scene.Instances {};
    defer bishop_instance.deinit(allocator);
    try bishop_instance.ensureTotalCapacity(allocator, 4);
    bishop_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.c1.toTransform(),
        .material_index = 1,
    });
    bishop_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.f1.toTransform(),
        .material_index = 1,
    });
    bishop_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.c8.toTransform().mul(black_rotation),
        .material_index = 2,
    });
    bishop_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.f8.toTransform().mul(black_rotation),
        .material_index = 2,
    });

    var king_instance = Scene.Instances {};
    defer king_instance.deinit(allocator);
    try king_instance.ensureTotalCapacity(allocator, 2);
    king_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.e1.toTransform(),
        .material_index = 1,
    });
    king_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.e8.toTransform().mul(black_rotation),
        .material_index = 2,
    });

    var queen_instance = Scene.Instances {};
    defer queen_instance.deinit(allocator);
    try queen_instance.ensureTotalCapacity(allocator, 2);
    queen_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.d1.toTransform(),
        .material_index = 1,
    });
    queen_instance.appendAssumeCapacity(.{
        .initial_transform = Coord.d8.toTransform().mul(black_rotation),
        .material_index = 2,
    });

    const instances = [_]Scene.Instances {
        board_instance,
        pawn_instance,
        rook_instance,
        knight_instance,
        bishop_instance,
        king_instance,
        queen_instance,
    };

    const mesh_filepaths = [_][]const u8 {
        chess_set.board.model_path,
        chess_set.pawn.model_path,
        chess_set.rook.model_path,
        chess_set.knight.model_path,
        chess_set.bishop.model_path,
        chess_set.king.model_path,
        chess_set.queen.model_path,
    };

    const scene = try Scene.create(vc, commands, materials, background_filepath, &mesh_filepaths, instances, allocator);
        
    return Self {
        .scene = scene,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator) void {
    self.scene.destroy(vc, allocator);
}
