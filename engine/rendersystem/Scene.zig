// a scene contains:
// - a list of meshes
// - an acceleration structure/mesh heirarchy
// - materials
// - a background

const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");

const VulkanContext = @import("./VulkanContext.zig");
const MeshData = @import("../Object.zig");
const ImageManager = @import("./ImageManager.zig");
const MaterialManager = @import("./MaterialManager.zig");

const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const descriptor = @import("./descriptor.zig");
const SceneDescriptorLayout = descriptor.SceneDescriptorLayout;
const BackgroundDescriptorLayout = descriptor.BackgroundDescriptorLayout;

const Background = @import("./Background.zig");
const MeshManager = @import("./MeshManager.zig");
const Accel = @import("./Accel.zig");
const utils = @import("./utils.zig");
const asset = @import("../asset.zig");

const vector = @import("../vector.zig");
const Mat3x4 = vector.Mat3x4(f32);
const F32x4 = vector.Vec4(f32);
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);
const U32x3 = vector.Vec3(u32);

pub const Material = MaterialManager.Material;
pub const Instances = Accel.Instances;
pub const InstanceMeshInfo = Accel.MeshInfo;

background: Background,

material_manager: MaterialManager,

mesh_manager: MeshManager,
accel: Accel,

instance_info: []InstanceMeshInfo, // used to update heirarchy transforms

sampler: vk.Sampler,
descriptor_set: vk.DescriptorSet,

const Self = @This();

fn gltfMaterialToMaterial(gltf_material: Gltf.Material) Material {
    const color = if (gltf_material.metallic_roughness.base_color_texture) |_| ImageManager.TextureSource {
        .color = undefined, // TODO
    } else ImageManager.TextureSource {
        .color = F32x3.new(gltf_material.metallic_roughness.base_color_factor[0], gltf_material.metallic_roughness.base_color_factor[1], gltf_material.metallic_roughness.base_color_factor[2])
    };

    const roughness = if (gltf_material.metallic_roughness.metallic_roughness_texture) |_| ImageManager.TextureSource {
        .color = undefined, // TODO
    } else ImageManager.TextureSource {
        .greyscale = gltf_material.metallic_roughness.roughness_factor,
    };

    const normal = if (gltf_material.normal_texture) |_| ImageManager.TextureSource {
        .color = undefined, // TODO
    } else ImageManager.TextureSource {
        .color = F32x3.new(0.5, 0.5, 1.0),
    };

    return Material {
        .color = color,
        .roughness = roughness,
        .normal = normal,
        .values = .{
            .metalness = gltf_material.metallic_roughness.metallic_factor,
        }
    };
}

// TODO: textures/camera, proper material/mesh linking

pub fn fromGlb(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, filepath: []const u8, background_dir: []const u8, descriptor_layout: *const SceneDescriptorLayout, background_descriptor_layout: *const BackgroundDescriptorLayout) !Self {
    // background atm unrelated to gltf
    const sampler = try ImageManager.createSampler(vc);
    var background = try Background.create(vc, vk_allocator, allocator, commands, background_dir, background_descriptor_layout, sampler);
    errdefer background.destroy(vc, allocator);

    // get the gltf
    var gltf = Gltf.init(allocator);
    defer gltf.deinit();

    const buffer = try std.fs.cwd().readFileAlloc(
        allocator,
        filepath,
        512_000,
    );
    defer allocator.free(buffer);
    try gltf.parse(buffer);

    // materials
    var material_manager = blk: {
        const materials = try allocator.alloc(Material, gltf.data.materials.items.len);
        defer allocator.free(materials);

        for (gltf.data.materials.items) |material, i| {
            materials[i] = gltfMaterialToMaterial(material);
        }

        break :blk try MaterialManager.create(vc, vk_allocator, allocator, commands, materials);
    };
    errdefer material_manager.destroy(vc, allocator);

    // meshes
    var mesh_manager = blk: {
        // our meshes actually correspond to gltf primatives

        var objects = std.ArrayList(MeshData).init(allocator);
        defer objects.deinit();
        defer for (objects.items) |*object| object.destroy(allocator);

        for (gltf.data.meshes.items) |mesh| {
            for (mesh.primitives.items) |primitive| {
                // get indices
                const indices = blk2: {
                    var indices = std.ArrayList(u16).init(allocator);
                    defer indices.deinit();

                    const accessor = gltf.data.accessors.items[primitive.indices.?];
                    gltf.getDataFromBufferView(u16, &indices, accessor, gltf.glb_binary.?);

                    // convert to U32x3
                    var actual_indices = try allocator.alloc(U32x3, indices.items.len / 3);
                    for (actual_indices) |*index, i| {
                        index.* = U32x3.new(indices.items[i * 3 + 0], indices.items[i * 3 + 1], indices.items[i * 3 + 2]);
                    }
                    break :blk2 actual_indices;
                };
                errdefer allocator.free(indices);

                const vertices = blk2: {
                    var positions = std.ArrayList(f32).init(allocator);
                    defer positions.deinit();
                    var texcoords = std.ArrayList(f32).init(allocator);
                    defer texcoords.deinit();

                    for (primitive.attributes.items) |attribute| {
                        switch (attribute) {
                            .position => |accessor_index| {
                                const accessor = gltf.data.accessors.items[accessor_index];
                                gltf.getDataFromBufferView(f32, &positions, accessor, gltf.glb_binary.?);
                            },
                            .texcoord => |accessor_index| {
                                const accessor = gltf.data.accessors.items[accessor_index];
                                gltf.getDataFromBufferView(f32, &texcoords, accessor, gltf.glb_binary.?);
                            },
                            else => return error.UnhandledAttribute,
                        }
                    }

                    const vertices = try allocator.alloc(MeshData.Vertex, positions.items.len / 3);
                    for (vertices) |*vertex, i| {
                        vertex.* = MeshData.Vertex {
                            .position = F32x3.new(positions.items[i * 3 + 0], positions.items[i * 3 + 1], positions.items[i * 3 + 2]),
                            .texcoord = F32x2.new(texcoords.items[i * 2 + 0], texcoords.items[i * 2 + 1]),
                        };
                    }

                    break :blk2 vertices;
                };
                errdefer allocator.free(vertices);

                // get vertices
                try objects.append(MeshData {
                    .vertices = vertices,
                    .indices = indices,
                });
            }
        }

        break :blk try MeshManager.create(vc, vk_allocator, allocator, commands, objects.items);
    };
    errdefer mesh_manager.destroy(vc, allocator);

    // go over heirarchy, finding meshes
    var instances = blk: {
        var instances = Instances {};
        errdefer instances.deinit(allocator);

        // not most efficient way but simplest and does the trick
        for (gltf.data.nodes.items) |node| {
            if (node.mesh) |mesh_idx| {
                _ = mesh_idx;
                const mat = Gltf.getGlobalTransform(&gltf.data, node);

                try instances.append(allocator, .{
                    .mesh_info = .{
                        .transform = Mat3x4.new(
                            F32x4.new(mat[0][0], mat[0][1], mat[0][2], mat[0][3]),
                            F32x4.new(mat[1][0], mat[1][1], mat[1][2], mat[1][3]),
                            F32x4.new(mat[2][0], mat[2][1], mat[2][2], mat[2][3]),
                        ),
                        .mesh_index = 0, // TODO
                    },
                    .material_index = 0, // TODO
                });
            }
        }

        break :blk instances;
    };
    errdefer instances.deinit(allocator);

    var accel = try Accel.create(vc, vk_allocator, allocator, commands, mesh_manager, instances);
    errdefer accel.destroy(vc, allocator);

    const instance_info = @ptrCast([*]InstanceMeshInfo, (try allocator.realloc(instances.bytes[0..instances.capacity * @sizeOf(Instances.Elem)], @sizeOf(InstanceMeshInfo) * instances.len)).ptr)[0..instances.len];

    const image_infos = try allocator.alloc(vk.DescriptorImageInfo, material_manager.textures.data.len);
    defer allocator.free(image_infos);

    const texture_views = material_manager.textures.data.items(.view);
    for (image_infos) |*info, i| {
        info.* = .{
            .sampler = .null_handle,
            .image_view = texture_views[i],
            .image_layout = .shader_read_only_optimal,
        };
    }

    const descriptor_set = (try descriptor_layout.allocate_sets(vc, 1, [6]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .acceleration_structure_khr,
            .p_image_info = undefined,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
            .p_next = &vk.WriteDescriptorSetAccelerationStructureKHR {
                .acceleration_structure_count = 1,
                .p_acceleration_structures = utils.toPointerType(&accel.tlas_handle),
            },
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .sampler,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = sampler,
                .image_view = .null_handle,
                .image_layout = undefined,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 2,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
                .buffer = material_manager.values.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 3,
            .dst_array_element = 0,
            .descriptor_count = @intCast(u32, image_infos.len),
            .descriptor_type = .sampled_image,
            .p_image_info = image_infos.ptr,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 4,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
                .buffer = mesh_manager.addresses_buffer.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 5,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
                .buffer = accel.instance_buffer.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
    }))[0];

    try utils.setDebugName(vc, descriptor_set, "Scene");

    return Self {
        .background = background,

        .material_manager = material_manager,
        .mesh_manager = mesh_manager,

        .accel = accel,
        .instance_info = instance_info,

        .sampler = sampler,
        .descriptor_set = descriptor_set,
    };
}

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, materials: []const Material, background_dir: []const u8, mesh_filepaths: []const []const u8, instances: Instances, descriptor_layout: *const SceneDescriptorLayout, background_descriptor_layout: *const BackgroundDescriptorLayout) !Self {
    var material_manager = try MaterialManager.create(vc, vk_allocator, allocator, commands, materials);
    errdefer material_manager.destroy(vc, allocator);

    const image_infos = try allocator.alloc(vk.DescriptorImageInfo, materials.len * 3);
    defer allocator.free(image_infos);

    const texture_views = material_manager.textures.data.items(.view);
    for (image_infos) |*info, i| {
        info.* = .{
            .sampler = .null_handle,
            .image_view = texture_views[i],
            .image_layout = .shader_read_only_optimal,
        };
    }

    const objects = try allocator.alloc(MeshData, mesh_filepaths.len);
    defer allocator.free(objects);
    defer for (objects) |*object| object.destroy(allocator);

    for (mesh_filepaths) |mesh_filepath, i| {
        const file = try asset.openAsset(allocator, mesh_filepath);
        defer file.close();

        objects[i] = try MeshData.fromObj(allocator, file);
    }

    var mesh_manager = try MeshManager.create(vc, vk_allocator, allocator, commands, objects);
    errdefer mesh_manager.destroy(vc, allocator);

    var accel = try Accel.create(vc, vk_allocator, allocator, commands, mesh_manager, instances);
    errdefer accel.destroy(vc, allocator);

    const instance_info = @ptrCast([*]InstanceMeshInfo, (try allocator.realloc(instances.bytes[0..instances.capacity * @sizeOf(Instances.Elem)], @sizeOf(InstanceMeshInfo) * instances.len)).ptr)[0..instances.len];

    const sampler = try ImageManager.createSampler(vc);

    const background = try Background.create(vc, vk_allocator, allocator, commands, background_dir, background_descriptor_layout, sampler);

    const descriptor_set = (try descriptor_layout.allocate_sets(vc, 1, [6]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .acceleration_structure_khr,
            .p_image_info = undefined,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
            .p_next = &vk.WriteDescriptorSetAccelerationStructureKHR {
                .acceleration_structure_count = 1,
                .p_acceleration_structures = utils.toPointerType(&accel.tlas_handle),
            },
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .sampler,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = sampler,
                .image_view = .null_handle,
                .image_layout = undefined,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 2,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
                .buffer = material_manager.values.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 3,
            .dst_array_element = 0,
            .descriptor_count = @intCast(u32, image_infos.len),
            .descriptor_type = .sampled_image,
            .p_image_info = image_infos.ptr,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 4,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
                .buffer = mesh_manager.addresses_buffer.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 5,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
                .buffer = accel.instance_buffer.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
    }))[0];

    try utils.setDebugName(vc, descriptor_set, "Scene");

    return Self {
        .background = background,

        .material_manager = material_manager,
        .mesh_manager = mesh_manager,

        .accel = accel,
        .instance_info = instance_info,

        .sampler = sampler,
        .descriptor_set = descriptor_set,
    };
}

pub fn updateTransform(self: *Self, index: u32, new_transform: Mat3x4) void {
    self.instance_info[index].transform = new_transform;
    self.accel.updateTlas(self.instance_info);
}

pub fn updateVisibility(self: *Self, index: u32, visible: bool) void {
    self.instance_info[index].visible = visible;
    self.accel.updateTlas(self.instance_info);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    allocator.free(self.instance_info);

    vc.device.destroySampler(self.sampler, null);

    self.background.destroy(vc, allocator);
    self.material_manager.destroy(vc, allocator);
    self.mesh_manager.destroy(vc, allocator);
    self.accel.destroy(vc, allocator);
}
