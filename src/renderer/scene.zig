const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("../renderer/VulkanContext.zig");
const MeshData = @import("../utils/Object.zig");
const Images = @import("../renderer/images.zig");
const Image = Images.Images(1);

const TransferCommands = @import("../renderer/commands.zig").ComputeCommands;

const mesh = @import("../renderer/mesh.zig");
const accels = @import("../renderer/accels.zig");

pub const SceneObject = struct {
    mesh_data: MeshData,
    material: accels.Material,
};

pub fn Scene(comptime texture_count: comptime_int, comptime unique_object_count: comptime_int, comptime duplicate_objects_counts: [unique_object_count]comptime_int) type {
    const Meshes = mesh.Meshes(unique_object_count);

    const Accels = accels.Accels(unique_object_count, duplicate_objects_counts);
    const BottomLevelAccels = Accels.BottomLevelAccels;
    const TopLevelAccel = Accels.TopLevelAccel;

    comptime var total_object_count = 0;
    comptime for (duplicate_objects_counts) |count| {
        total_object_count += count;
    };

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

        pub fn create(vc: *const VulkanContext, commands: *TransferCommands, comptime texture_sets: [texture_count]TextureSet, comptime background_filepath: []const u8, objects: [unique_object_count]SceneObject, transforms: [total_object_count][3][4]f32) !Self {
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

            const mesh_data: [unique_object_count]MeshData = undefined;
            inline for (objects) |object, i| {
                mesh_data[i] = object.mesh_data;
            }

            var geometries: [unique_object_count]vk.AccelerationStructureGeometryKHR = undefined;
            var build_infos: [unique_object_count]vk.AccelerationStructureBuildRangeInfoKHR = undefined;
            var build_infos_ref: [unique_object_count]*const vk.AccelerationStructureBuildRangeInfoKHR = undefined;
            comptime var i = 0;
            comptime while (i < unique_object_count) : (i += 1) {
                build_infos_ref[i] = &build_infos[i];
            };
            var meshes = try Meshes.create(vc, commands, &mesh_data, &geometries, &build_infos);
            errdefer meshes.destroy(vc);

            const materials: [total_object_count]accels.Material = undefined;
            var offset = 0;
            inline for (objects) |object, j| {
                comptime var k = 0;
                inline while (k < duplicate_objects_counts[j]) : (k += 1) {
                    materials[offset + k] = object.material;
                    offset += 1;
                }
            }

            var blases = try BottomLevelAccels.create(vc, commands, &geometries, &build_infos_ref, &transforms, &materials);
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
