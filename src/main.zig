const std = @import("std");

const Engine = @import("./renderer/Engine.zig");
const Scene = @import("./logic/scene.zig");
const F32x3 = @import("./utils/zug.zig").Vec3(f32);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    const texture_sets = comptime [_]Scene.Material {
        Scene.Material {
            .color = .{
                .filepath = "../../assets/textures/board/color.dds",
            },
            .roughness = .{
                .greyscale = 0.3,
            },
            .normal = .{
                .filepath = "../../assets/textures/board/normal.dds"
            },
            .metallic = 0.4,
            .ior = 1.35,
        },
        Scene.Material {
            .color = .{
                .color = F32x3.new(0.653, 0.653, 0.653)
            },
            .roughness = .{
                .greyscale = 0.15,
            },
            .normal = .{
                .color = F32x3.new(0.5, 0.5, 1.0)
            },
            .metallic = 0.2,
            .ior = 1.5,
        },
        Scene.Material {
            .color = .{
                .color = F32x3.new(0.0004, 0.0025, 0.0096)
            },
            .roughness = .{
                .greyscale = 0.15,
            },
            .normal = .{
                .color = F32x3.new(0.5, 0.5, 1.0)
            },
            .metallic = 0.2,
            .ior = 1.5,
        },
    };

    var engine = try Engine.create(texture_sets.len, allocator);
    defer engine.destroy(allocator);

    const chess_set = Scene.ChessSet {
        .board = .{
            .material_index = 0,
            .model_path = "../../assets/models/board.obj"
        },

        .pawn = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/pawn.obj"
        },
        .rook = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/rook.obj"
        },
        .knight = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/knight.obj"
        },
        .bishop = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/bishop.obj"
        },
        .king = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/king.obj"
        },
        .queen = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/queen.obj"
        },
    };

    var scene = try Scene.Scene(texture_sets.len).create(&engine.context, &engine.transfer_commands, texture_sets, "../../assets/textures/skybox.dds", chess_set, allocator);
    defer scene.destroy(&engine.context, allocator);

    engine.setCallbacks();
    engine.setScene(&scene);

    try engine.run(allocator);

    std.log.info("Program completed!.", .{});
}
