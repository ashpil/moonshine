const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("../renderer/VulkanContext.zig");
const MeshData = @import("../utils/Object.zig");
const Images = @import("../renderer/images.zig");
const Image = Images.Images(1);

const TransferCommands = @import("../renderer/commands.zig").ComputeCommands;

const mesh = @import("../renderer/mesh.zig");
const Meshes = mesh.Meshes(object_count);
const accels = @import("../renderer/accels.zig");
const Accels = accels.Accels(object_count, .{ 1, 16, 4, 4, 4, 2, 2 });
const BottomLevelAccels = Accels.BottomLevelAccels;
const TopLevelAccel = Accels.TopLevelAccel;

pub const TextureSet = struct {
    color: Images.TextureSource,
    roughness: Images.TextureSource,
    normal: Images.TextureSource,
};

pub const Piece = struct {
    model_path: []const u8,
    black_material: accels.Material,
    white_material: accels.Material,
};

pub const Board = struct {
    model_path: []const u8,
    material: accels.Material,
};

pub const ChessSet = struct {
    board: Board,

    pawn: Piece,
    rook: Piece,
    knight: Piece,
    bishop: Piece,
    king: Piece,
    queen: Piece,
};

const object_count = 7;

pub fn Scene(comptime texture_count: comptime_int) type {
    return struct {

        const Textures = Images.Images(texture_count);

        background: Image,

        color_textures: Textures,
        roughness_textures: Textures,
        normal_textures: Textures,

        meshes: Meshes,
        blases: BottomLevelAccels,
        tlas: TopLevelAccel,

        const Self = @This();

        pub fn create(vc: *const VulkanContext, commands: *TransferCommands, comptime texture_sets: [texture_count]TextureSet, comptime background_filepath: []const u8, comptime chess_set: ChessSet, allocator: *std.mem.Allocator) !Self {
            const background = try Image.createTexture(vc, .{
                .{
                    .filepath = background_filepath,
                }
            }, commands);

            comptime var color_sources: [texture_count]Images.TextureSource = undefined;
            comptime var roughness_sources: [texture_count]Images.TextureSource = undefined;
            comptime var normal_sources: [texture_count]Images.TextureSource = undefined;

            comptime for (texture_sets) |set, i| {
                color_sources[i] = set.color;
                roughness_sources[i] = set.roughness;
                normal_sources[i] = set.normal;
            };

            const color_textures = try Textures.createTexture(vc, color_sources, commands);
            const roughness_textures = try Textures.createTexture(vc, roughness_sources, commands);
            const normal_textures = try Textures.createTexture(vc, normal_sources, commands);

            var board = try MeshData.fromObj(allocator, @embedFile(chess_set.board.model_path));
            defer board.destroy(allocator);

            var pawn = try MeshData.fromObj(allocator, @embedFile(chess_set.pawn.model_path));
            defer pawn.destroy(allocator);

            var rook = try MeshData.fromObj(allocator, @embedFile(chess_set.rook.model_path));
            defer rook.destroy(allocator);

            var knight = try MeshData.fromObj(allocator, @embedFile(chess_set.knight.model_path));
            defer knight.destroy(allocator);

            var bishop = try MeshData.fromObj(allocator, @embedFile(chess_set.bishop.model_path));
            defer bishop.destroy(allocator);

            var king = try MeshData.fromObj(allocator, @embedFile(chess_set.king.model_path));
            defer king.destroy(allocator);

            var queen = try MeshData.fromObj(allocator, @embedFile(chess_set.queen.model_path));
            defer queen.destroy(allocator);

            const objects = [object_count] MeshData {
                board,
                pawn,
                rook,
                knight,
                bishop,
                king,
                queen,
            };

            var geometries: [object_count]vk.AccelerationStructureGeometryKHR = undefined;
            var build_infos: [object_count]vk.AccelerationStructureBuildRangeInfoKHR = undefined;
            var build_infos_ref: [object_count]*const vk.AccelerationStructureBuildRangeInfoKHR = undefined;
            comptime var i = 0;
            comptime while (i < object_count) : (i += 1) {
                build_infos_ref[i] = &build_infos[i];
            };
            var meshes = try Meshes.create(vc, commands, &objects, &geometries, &build_infos);
            errdefer meshes.destroy(vc);

            const matrices = [33][3][4]f32 {
                // board
                .{
                    .{1.0, 0.0, 0.0, 0.0},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.0},
                },
                // white pawns
                .{
                    .{1.0, 0.0, 0.0, -0.175},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, -0.125},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, -0.075},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, -0.025},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, 0.025},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, 0.075},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, 0.125},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, 0.175},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.125},
                },
                // black pawns
                .{
                    .{1.0, 0.0, 0.0, -0.175},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, -0.125},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, -0.075},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, -0.025},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, 0.025},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, 0.075},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, 0.125},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.125},
                },
                .{
                    .{1.0, 0.0, 0.0, 0.175},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.125},
                },
                // white rooks
                .{
                    .{1.0, 0.0, 0.0, 0.175},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.175},
                },
                .{
                    .{1.0, 0.0, 0.0, -0.175},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.175},
                },
                // black rooks
                .{
                    .{1.0, 0.0, 0.0, 0.175},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.175},
                },
                .{
                    .{1.0, 0.0, 0.0, -0.175},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.175},
                },
                // white knights
                .{
                    .{1.0, 0.0, 0.0, 0.125},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.175},
                },
                .{
                    .{1.0, 0.0, 0.0, -0.125},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.175},
                },
                // black knights
                .{
                    .{-1.0, 0.0, 0.0, 0.125},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, -1.0, 0.175},
                },
                .{
                    .{-1.0, 0.0, 0.0, -0.125},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, -1.0, 0.175},
                },
                // white bishops
                .{
                    .{1.0, 0.0, 0.0, 0.075},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.175},
                },
                .{
                    .{1.0, 0.0, 0.0, -0.075},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.175},
                },
                // black bishops
                .{
                    .{-1.0, 0.0, 0.0, 0.075},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, -1.0, 0.175},
                },
                .{
                    .{-1.0, 0.0, 0.0, -0.075},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, -1.0, 0.175},
                },
                // white king
                .{
                    .{1.0, 0.0, 0.0, 0.025},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.175},
                },
                // black king
                .{
                    .{1.0, 0.0, 0.0, 0.025},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.175},
                },
                // white queen
                .{
                    .{1.0, 0.0, 0.0, -0.025},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, -0.175},
                },
                // black queen
                .{
                    .{1.0, 0.0, 0.0, -0.025},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.175},
                },
            };
            var blases = try BottomLevelAccels.create(vc, commands, &geometries, &build_infos_ref, &matrices, [33]accels.Material {
                chess_set.board.material,

                chess_set.pawn.white_material,
                chess_set.pawn.white_material,
                chess_set.pawn.white_material,
                chess_set.pawn.white_material,
                chess_set.pawn.white_material,
                chess_set.pawn.white_material,
                chess_set.pawn.white_material,
                chess_set.pawn.white_material,
                chess_set.pawn.black_material,
                chess_set.pawn.black_material,
                chess_set.pawn.black_material,
                chess_set.pawn.black_material,
                chess_set.pawn.black_material,
                chess_set.pawn.black_material,
                chess_set.pawn.black_material,
                chess_set.pawn.black_material,

                chess_set.rook.white_material,
                chess_set.rook.white_material,
                chess_set.rook.black_material,
                chess_set.rook.black_material,

                chess_set.knight.white_material,
                chess_set.knight.white_material,
                chess_set.knight.black_material,
                chess_set.knight.black_material,

                chess_set.bishop.white_material,
                chess_set.bishop.white_material,
                chess_set.bishop.black_material,
                chess_set.bishop.black_material,

                chess_set.king.white_material,
                chess_set.king.black_material,

                chess_set.queen.white_material,
                chess_set.queen.black_material,
            });
            errdefer blases.destroy(vc);

            var tlas = try TopLevelAccel.create(vc, commands, &blases);
            errdefer tlas.destroy(vc);

            return Self {
                .background = background,

                .color_textures = color_textures,
                .roughness_textures = roughness_textures,
                .normal_textures = normal_textures,

                .meshes = meshes,
                .blases = blases,
                .tlas = tlas,
            };
        }

        pub fn destroy(self: *Self, vc: *const VulkanContext) void {
            self.background.destroy(vc);
            self.color_textures.destroy(vc);
            self.roughness_textures.destroy(vc);
            self.normal_textures.destroy(vc);
            self.meshes.destroy(vc);
            self.blases.destroy(vc);
            self.tlas.destroy(vc);
        }
    };
}
