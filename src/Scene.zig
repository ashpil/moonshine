const std = @import("std");
const vk = @import("vulkan");
const Object = @import("./Object.zig");

const VulkanContext = @import("./VulkanContext.zig");

const Meshes = @import("./mesh.zig").Meshes(object_count);
const Accels = @import("./accels.zig").Accels(object_count);
const BottomLevelAccels = Accels.BottomLevelAccels;
const TopLevelAccel = Accels.TopLevelAccel;

const TransferCommands = @import("./commands.zig").ComputeCommands;

const object_count = 2;

meshes: Meshes,
blases: BottomLevelAccels,
tlas: TopLevelAccel,

const Self = @This();

pub fn create(vc: *const VulkanContext, allocator: *std.mem.Allocator, commands: *TransferCommands) !Self {

    const cube_obj = @embedFile("../assets/cube.obj");
    var cube = try Object.fromObj(allocator, cube_obj);
    defer cube.destroy(allocator);

    const pawn_obj = @embedFile("../assets/pawn.obj");
    var pawn = try Object.fromObj(allocator, pawn_obj);
    defer pawn.destroy(allocator);

    const objects = [object_count]Object {
        cube,
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
            .{3.0, 0.0, 0.0, 0.0},
            .{0.0, 0.5, 0.0, -0.8},
            .{0.0, 0.0, 3.0, 0.0},
        },
        .{
            .{0.8, 0.0, 0.0, 0.0},
            .{0.0, 0.8, 0.0, 0.0},
            .{0.0, 0.0, 0.8, 0.0},
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
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.meshes.destroy(vc);
    self.blases.destroy(vc);
    self.tlas.destroy(vc);
}
