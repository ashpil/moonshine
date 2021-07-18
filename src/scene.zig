const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./vulkan_context.zig");

const MeshesFn = @import("./mesh.zig").Meshes;
const BottomLevelAccelsFn = @import("./acceleration_structure.zig").BottomLevelAccels;
const TopLevelAccelFn = @import("./acceleration_structure.zig").TopLevelAccel;

const TransferCommands = @import("./commands.zig").ComputeCommands;

const Vec3 = @import("./zug.zig").Vec3(f32);

const vertices = [_]Vec3 {
    Vec3.new(0.0, -0.5, 0.0),
    Vec3.new(0.5, 0.5, 0.0),
    Vec3.new(-0.5, 0.5, 0.0),
};

pub fn Scene(comptime comp_vc: *VulkanContext, comptime comp_allocator: *std.mem.Allocator) type {
    return struct {

        const Meshes = MeshesFn(comp_vc, comp_allocator);
        const BottomLevelAccels = BottomLevelAccelsFn(comp_vc, comp_allocator);
        const TopLevelAccel = TopLevelAccelFn(comp_vc, comp_allocator);

        meshes: Meshes,
        blases: BottomLevelAccels,
        tlas: TopLevelAccel,

        const Self = @This();

        const vc = comp_vc;
        const allocator = comp_allocator;

        pub fn create(commands: *TransferCommands(comp_vc)) !Self {

            var meshes = try Meshes.createOne(commands, &vertices);

            const geometry = try meshes.getGeometries(allocator, &.{ vertices.len });
            defer allocator.free(geometry);

            const build_infos = [_]*const vk.AccelerationStructureBuildRangeInfoKHR {
                &.{
                    .primitive_count = 1,
                    .primitive_offset = 0,
                    .transform_offset = 0,
                    .first_vertex = 0,
                },
            };

            const blases = try BottomLevelAccels.create(commands, geometry, &build_infos);
            const tlas = try TopLevelAccel.create(commands, &blases);

            return Self {
                .meshes = meshes,
                .blases = blases,
                .tlas = tlas,
            };
        }

        pub fn destroy(self: *Self) void {
            self.meshes.destroy();
            self.blases.destroy();
            self.tlas.destroy();
        }
    };
}
