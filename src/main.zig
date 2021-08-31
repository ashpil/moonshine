const std = @import("std");

const Engine = @import("./renderer/Engine.zig");
const Scene = @import("./logic/scene.zig");
const F32x3 = @import("./utils/zug.zig").Vec3(f32);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    const texture_sets = comptime [_]Scene.TextureSet {
        Scene.TextureSet {
            .color = .{
                .filepath = "../../assets/textures/board/color.dds",
            },
            .roughness = .{
                .greyscale = 0.3,
            },
            .normal = .{
                .filepath = "../../assets/textures/board/normal.dds"
            }
        },
        Scene.TextureSet {
            .color = .{
                .color = F32x3.new(0.653, 0.653, 0.653)
            },
            .roughness = .{
                .greyscale = 0.15,
            },
            .normal = .{
                .color = F32x3.new(0.5, 0.5, 1.0)
            }
        },
        Scene.TextureSet {
            .color = .{
                .color = F32x3.new(0.0004, 0.0025, 0.0096)
            },
            .roughness = .{
                .greyscale = 0.15,
            },
            .normal = .{
                .color = F32x3.new(0.5, 0.5, 1.0)
            }
        },
    };

    var engine = try Engine.create(texture_sets.len, allocator);
    defer engine.destroy(allocator);

    const chess_set = Scene.ChessSet {
        .models_dir = "../../assets/models/",
        .board = .{
            .material = .{
                .metallic = 0.4,
                .ior = 1.35,
                .texture_index = 0,
            },
        },

        .pawn = .{
            .white_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 1,
            },
            .black_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 2,
            },
        },
        .rook = .{
            .white_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 1,
            },
            .black_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 2,
            },
        },
        .knight = .{
            .white_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 1,
            },
            .black_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 2,
            },
        },
        .bishop = .{
            .white_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 1,
            },
            .black_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 2,
            },
        },
        .king = .{
            .white_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 1,
            },
            .black_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 2,
            },
        },
        .queen = .{
            .white_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 1,
            },
            .black_material = .{
                .metallic = 0.2,
                .ior = 1.5,
                .texture_index = 2,
            },
        },
    };

    var scene = try Scene.Scene(texture_sets.len).create(&engine.context, &engine.transfer_commands, texture_sets, "../../assets/textures/skybox.dds", chess_set, allocator);
    defer scene.destroy(&engine.context);

    engine.setCallbacks();
    engine.setScene(&scene);

    try engine.run(allocator);

    std.log.info("Program completed!.", .{});
}
