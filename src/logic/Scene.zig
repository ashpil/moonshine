const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("../renderer/VulkanContext.zig");
const MeshData = @import("../utils/Object.zig");
const Images = @import("../renderer/Images.zig");

const TransferCommands = @import("../renderer/commands.zig").ComputeCommands;

const Meshes = @import("../renderer/Meshes.zig");
const Accel = @import("../renderer/Accel.zig");
const utils = @import("../renderer/utils.zig");

pub const Material = struct {
    color: Images.TextureSource,
    roughness: Images.TextureSource,
    normal: Images.TextureSource,

    metallic: f32,
    ior: f32,
};

pub const GpuMaterial = packed struct {
    metallic: f32,
    ior: f32,
};

pub const Piece = struct {
    black_material_index: u32,
    white_material_index: u32,
    model_path: []const u8,
};

pub const Board = struct {
    material_index: u32,
    model_path: []const u8,
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

background: Images,

color_textures: Images,
roughness_textures: Images,
normal_textures: Images,

meshes: Meshes,
accel: Accel,

materials_buffer: vk.Buffer,
materials_memory: vk.DeviceMemory,

const Self = @This();

pub fn create(vc: *const VulkanContext, commands: *TransferCommands, comptime materials: []const Material, comptime background_filepath: []const u8, comptime chess_set: ChessSet, allocator: *std.mem.Allocator) !Self {
    const object_count = 7;

    const background = try Images.createTexture(vc, allocator, &[_]Images.TextureSource {
        Images.TextureSource {
            .filepath = background_filepath,
        }
    }, commands);

    comptime var color_sources: [materials.len]Images.TextureSource = undefined;
    comptime var roughness_sources: [materials.len]Images.TextureSource = undefined;
    comptime var normal_sources: [materials.len]Images.TextureSource = undefined;

    comptime var gpu_materials: [materials.len]GpuMaterial = undefined;

    comptime for (materials) |set, i| {
        color_sources[i] = set.color;
        roughness_sources[i] = set.roughness;
        normal_sources[i] = set.normal;

        gpu_materials[i].ior = set.ior;
        gpu_materials[i].metallic = set.metallic;
    };

    const color_textures = try Images.createTexture(vc, allocator, &color_sources, commands);
    const roughness_textures = try Images.createTexture(vc, allocator, &roughness_sources, commands);
    const normal_textures = try Images.createTexture(vc, allocator, &normal_sources, commands);

    var materials_buffer: vk.Buffer = undefined;
    var materials_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, @sizeOf(GpuMaterial) * materials.len, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }, .{ .device_local_bit = true }, &materials_buffer, &materials_memory);
    errdefer vc.device.freeMemory(materials_memory, null);
    errdefer vc.device.destroyBuffer(materials_buffer, null);

    try commands.uploadData(vc, materials_buffer, std.mem.asBytes(&gpu_materials));

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

    var geometry_infos = Accel.GeometryInfos {};
    defer geometry_infos.deinit(allocator);
    try geometry_infos.ensureTotalCapacity(allocator, object_count);

    var board_instance = Accel.Instances {};
    defer board_instance.deinit(allocator);
    try board_instance.ensureTotalCapacity(allocator, 1);
    board_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.0},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.0},
        },
        .material_index = 0,
    });

    var pawn_instance = Accel.Instances {};
    defer pawn_instance.deinit(allocator);
    try pawn_instance.ensureTotalCapacity(allocator, 16);
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.175},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.125},
        },
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.125},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.125},
        },
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.075},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.125},
        },
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.025},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.125},
        },
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.025},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.125},
        },
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.075},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.125},
        },
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.125},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.125},
        },
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.175},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.125},
        },
        .material_index = 1,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.175},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.125},
        },
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.125},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.125},
        },
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.075},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.125},
        },
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.075},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.125},
        },
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.025},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.125},
        },
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.075},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.125},
        },
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.125},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.125},
        },
        .material_index = 2,
    });
    pawn_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.175},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.125},
        },
        .material_index = 2,
    });

    var rook_instance = Accel.Instances {};
    defer rook_instance.deinit(allocator);
    try rook_instance.ensureTotalCapacity(allocator, 4);
    rook_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.175},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.175},
        },
        .material_index = 1,
    });
    rook_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.175},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.175},
        },
        .material_index = 1,
    });
    rook_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.175},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.175},
        },
        .material_index = 2,
    });
    rook_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.175},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.175},
        },
        .material_index = 2,
    });

    var knight_instance = Accel.Instances {};
    defer knight_instance.deinit(allocator);
    try knight_instance.ensureTotalCapacity(allocator, 4);
    knight_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.125},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.175},
        },
        .material_index = 1,
    });
    knight_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.125},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.175},
        },
        .material_index = 1,
    });
    knight_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{-1.0, 0.0, 0.0, 0.125},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, -1.0, 0.175},
        },
        .material_index = 2,
    });
    knight_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{-1.0, 0.0, 0.0, -0.125},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, -1.0, 0.175},
        },
        .material_index = 2,
    });

    var bishop_instance = Accel.Instances {};
    defer bishop_instance.deinit(allocator);
    try bishop_instance.ensureTotalCapacity(allocator, 4);
    bishop_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.075},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.175},
        },
        .material_index = 1,
    });
    bishop_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.075},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.175},
        },
        .material_index = 1,
    });
    bishop_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{-1.0, 0.0, 0.0, 0.075},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, -1.0, 0.175},
        },
        .material_index = 2,
    });
    bishop_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{-1.0, 0.0, 0.0, -0.075},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, -1.0, 0.175},
        },
        .material_index = 2,
    });

    var king_instance = Accel.Instances {};
    defer king_instance.deinit(allocator);
    try king_instance.ensureTotalCapacity(allocator, 2);
    king_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.025},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.175},
        },
        .material_index = 1,
    });
    king_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, 0.025},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.175},
        },
        .material_index = 2,
    });

    var queen_instance = Accel.Instances {};
    defer queen_instance.deinit(allocator);
    try queen_instance.ensureTotalCapacity(allocator, 2);
    queen_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.025},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -0.175},
        },
        .material_index = 1,
    });
    queen_instance.appendAssumeCapacity(.{
        .initial_transform = .{
            .{1.0, 0.0, 0.0, -0.025},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.175},
        },
        .material_index = 2,
    });

    const instances = [object_count]Accel.Instances {
        board_instance,
        pawn_instance,
        rook_instance,
        knight_instance,
        bishop_instance,
        king_instance,
        queen_instance,
    };
        
    comptime var i = 0;
    inline while (i < object_count) : (i += 1) {
        geometry_infos.appendAssumeCapacity(.{
            .geometry = undefined,
            .build_info = undefined,
            .instances = instances[i],
        });
    }

    const geometry_infos_slice = geometry_infos.slice();
    const geometries = geometry_infos_slice.items(.geometry);
    var build_infos: [object_count]vk.AccelerationStructureBuildRangeInfoKHR = undefined;
    
    var meshes = try Meshes.create(vc, commands, allocator, &objects, geometries, &build_infos);
    errdefer meshes.destroy(vc, allocator);

    var build_infos_ref = geometry_infos_slice.items(.build_info);
    i = 0;
    inline while (i < object_count) : (i += 1) {
        build_infos_ref[i] = &build_infos[i];
    }

    var accel = try Accel.create(vc, allocator, commands, geometry_infos);
    errdefer accel.destroy(vc, allocator);

    return Self {
        .background = background,

        .color_textures = color_textures,
        .roughness_textures = roughness_textures,
        .normal_textures = normal_textures,

        .materials_buffer = materials_buffer,
        .materials_memory = materials_memory,

        .meshes = meshes,
        .accel = accel,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator) void {
    self.background.destroy(vc, allocator);
    self.color_textures.destroy(vc, allocator);
    self.roughness_textures.destroy(vc, allocator);
    self.normal_textures.destroy(vc, allocator);
    self.meshes.destroy(vc, allocator);
    self.accel.destroy(vc, allocator);

    vc.device.destroyBuffer(self.materials_buffer, null);
    vc.device.freeMemory(self.materials_memory, null);
}
