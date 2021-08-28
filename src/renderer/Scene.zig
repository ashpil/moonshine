const std = @import("std");
const vk = @import("vulkan");
const Object = @import("./Object.zig");

const VulkanContext = @import("./VulkanContext.zig");

const Meshes = @import("./mesh.zig").Meshes(object_count);
const Accels = @import("./accels.zig").Accels(object_count);
const BottomLevelAccels = Accels.BottomLevelAccels;
const TopLevelAccel = Accels.TopLevelAccel;
const Images = @import("./images.zig").Images(object_count);

const TransferCommands = @import("./commands.zig").ComputeCommands;

const F32x3 = @import("./zug.zig").Vec3(f32);

const object_count = 2;

meshes: Meshes,
blases: BottomLevelAccels,
tlas: TopLevelAccel,

albedo_textures: Images,
roughness_textures: Images,
normal_textures: Images,

const Self = @This();

pub fn create(vc: *const VulkanContext, allocator: *std.mem.Allocator, commands: *TransferCommands) !Self {

    const board_obj = @embedFile("../../assets/models/board.obj");
    var board = try Object.fromObj(allocator, board_obj, 0.4, 1.35);
    defer board.destroy(allocator);

    const pawn_obj = @embedFile("../../assets/models/pawn.obj");
    var pawn = try Object.fromObj(allocator, pawn_obj, 0.2, 1.5);
    defer pawn.destroy(allocator);

    const objects = [object_count]Object {
        board,
        pawn,
    };

    const albedo_textures = try Images.createTexture(vc, comptime .{
        .{
            .filepath = "../../assets/textures/board/color.dds",
        }, 
        .{
            .color = F32x3.new(0.8, 0.8, 0.8),
        }
    }, commands);

    const roughness_textures = try Images.createTexture(vc, comptime .{
        .{
            .greyscale = 0.3,
        }, 
        .{
            .greyscale = 0.15,
        }
    }, commands);

    const normal_textures = try Images.createTexture(vc, comptime .{
        .{
            .filepath = "../../assets/textures/board/normal.dds",
        }, 
        .{
            .color = F32x3.new(0.5, 0.5, 1.0),
        }
    }, commands);

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
            .{1.0, 0.0, 0.0, 0.025},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.025},
        },
        .{
            .{1.0, 0.0, 0.0, 0.0},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.0},
        },
    };
    var blases = try BottomLevelAccels.create(vc, commands, &geometries, &build_infos_ref, &matrices);
    errdefer blases.destroy(vc);

    var tlas = try TopLevelAccel.create(vc, commands, &blases);
    errdefer tlas.destroy(vc);

    return Self {
        .meshes = meshes,
        .blases = blases,
        .tlas = tlas,
        .albedo_textures = albedo_textures,
        .roughness_textures = roughness_textures,
        .normal_textures = normal_textures,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.meshes.destroy(vc);
    self.blases.destroy(vc);
    self.tlas.destroy(vc);
    self.albedo_textures.destroy(vc);
    self.roughness_textures.destroy(vc);
    self.normal_textures.destroy(vc);
}
