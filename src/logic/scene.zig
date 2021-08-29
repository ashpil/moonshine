const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("../renderer/VulkanContext.zig");
const Object = @import("../renderer/Object.zig");
const Images = @import("../renderer/images.zig");
const Image = Images.Images(1);

const TransferCommands = @import("../renderer/commands.zig").ComputeCommands;

const Meshes = @import("../renderer/mesh.zig").Meshes(object_count);
const Accels = @import("../renderer/accels.zig").Accels(object_count);
const BottomLevelAccels = Accels.BottomLevelAccels;
const TopLevelAccel = Accels.TopLevelAccel;

pub const TextureSet = struct {
    color: Images.TextureSource,
    roughness: Images.TextureSource,
    normal: Images.TextureSource,
};

pub const Material = struct {
    metallic: f32,
    ior: f32,
    texture_index: u8,
};

pub const Piece = struct {
    model_path: []const u8,
    black_material: Material,
    white_material: Material,
};

pub const Board = struct {
    model_path: []const u8,
    material: Material,
};

pub const ChessSet = struct {
    board: Board,

    pawn: Piece,
    // rook: Piece,
    // knight: Piece,
    // bishop: Piece,
    // king: Piece,
    // queen: Piece,
};

const object_count = 2;

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

            const board_obj = @embedFile(chess_set.board.model_path);
            var board = try Object.fromObj(allocator, board_obj, chess_set.board.material.metallic, chess_set.board.material.ior);
            defer board.destroy(allocator);

            const pawn_obj = @embedFile(chess_set.pawn.model_path);
            var pawn = try Object.fromObj(allocator, pawn_obj, chess_set.pawn.white_material.metallic, chess_set.pawn.white_material.ior);
            defer pawn.destroy(allocator);

            const objects = [object_count]Object {
                board,
                pawn,
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

            const matrices = [object_count][3][4]f32 {
                .{
                    .{1.0, 0.0, 0.0, 0.0},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.0},
                },
                .{
                    .{1.0, 0.0, 0.0, 0.025},
                    .{0.0, 1.0, 0.0, 0.0},
                    .{0.0, 0.0, 1.0, 0.025},
                },
            };
            var blases = try BottomLevelAccels.create(vc, commands, &geometries, &build_infos_ref, &matrices);
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
