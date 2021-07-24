const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./vulkan_context.zig");

const Meshes = @import("./mesh.zig");
const BottomLevelAccels = @import("./acceleration_structure.zig").BottomLevelAccels;
const TopLevelAccel = @import("./acceleration_structure.zig").TopLevelAccel;

const TransferCommands = @import("./commands.zig").ComputeCommands;

const Vec3 = @import("./zug.zig").Vec3(f32);

const vertices = [_]Vec3 {
    Vec3.new(0.0, -0.5, 0.0),
    Vec3.new(0.5, 0.5, 0.0),
    Vec3.new(-0.5, 0.5, 0.0),
};

meshes: Meshes,
blases: BottomLevelAccels,
tlas: TopLevelAccel,

const Self = @This();

pub fn create(vc: *const VulkanContext, allocator: *std.mem.Allocator, commands: *TransferCommands) !Self {
    var meshes = try Meshes.createOne(vc, allocator, commands, &vertices);

    const geometry = try meshes.getGeometries(vc, allocator, &.{ vertices.len });
    defer allocator.free(geometry);

    const build_infos = [_]*const vk.AccelerationStructureBuildRangeInfoKHR {
        &.{
            .primitive_count = 1,
            .primitive_offset = 0,
            .transform_offset = 0,
            .first_vertex = 0,
        },
    };

    const blases = try BottomLevelAccels.create(vc, allocator, commands, geometry, &build_infos);
    const tlas = try TopLevelAccel.create(vc, commands, &blases);

    return Self {
        .meshes = meshes,
        .blases = blases,
        .tlas = tlas,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator) void {
    self.meshes.destroy(vc, allocator);
    self.blases.destroy(vc, allocator);
    self.tlas.destroy(vc);
}
