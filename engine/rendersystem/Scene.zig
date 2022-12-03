// a scene contains:
// - a list of meshes
// - an acceleration structure/mesh heirarchy
// - materials
// - a background

const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");
const zigimg = @import("zigimg");

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
pub const Model = Accel.Model;
pub const Skin = Accel.Skin;

background: Background,

material_manager: MaterialManager,

mesh_manager: MeshManager,
accel: Accel,

sampler: vk.Sampler,
descriptor_set: vk.DescriptorSet,

const Self = @This();

fn gltfMaterialToMaterial(allocator: std.mem.Allocator, gltf: Gltf, gltf_material: Gltf.Material) !Material {
    var color = ImageManager.TextureSource {
        .f32x3 = F32x3.new(gltf_material.metallic_roughness.base_color_factor[0], gltf_material.metallic_roughness.base_color_factor[1], gltf_material.metallic_roughness.base_color_factor[2])
    };
    if (gltf_material.metallic_roughness.base_color_texture) |texture| {
        const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
        std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

        // this gives us rgb --> need to convert to rgba
        var img = try zigimg.Image.fromMemory(allocator, image.data.?);
        defer img.deinit();

        var rgba = try zigimg.color.PixelStorage.init(allocator, .rgba32, img.pixels.len());
        for (img.pixels.rgb24) |pixel, i| {
            rgba.rgba32[i] = zigimg.color.Rgba32.initRgba(pixel.r, pixel.g, pixel.b, std.math.maxInt(u8));
        }
        color = ImageManager.TextureSource {
            .raw = .{
                .bytes = rgba.asBytes(),
                .width = @intCast(u32, img.width),
                .height = @intCast(u32, img.height),
                .format = .r8g8b8a8_srgb,
                .layout = .shader_read_only_optimal,
                .usage = .{ .sampled_bit = true },
            },
        };
    }

    var emissive = ImageManager.TextureSource {
        .f32x3 = F32x3.new(gltf_material.emissive_factor[0], gltf_material.emissive_factor[1], gltf_material.emissive_factor[2]),
    };
    if (gltf_material.emissive_texture) |texture| {
        const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
        std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

        // this gives us rgb --> need to convert to rgba
        var img = try zigimg.Image.fromMemory(allocator, image.data.?);
        defer img.deinit();

        var rgba = try zigimg.color.PixelStorage.init(allocator, .rgba32, img.pixels.len());
        for (img.pixels.rgb24) |pixel, i| {
            rgba.rgba32[i] = zigimg.color.Rgba32.initRgba(pixel.r, pixel.g, pixel.b, std.math.maxInt(u8));
        }
        emissive = ImageManager.TextureSource {
            .raw = .{
                .bytes = rgba.asBytes(),
                .width = @intCast(u32, img.width),
                .height = @intCast(u32, img.height),
                .format = .r8g8b8a8_srgb,
                .layout = .shader_read_only_optimal,
                .usage = .{ .sampled_bit = true },
            },
        };
    }

    var metalness = ImageManager.TextureSource {
        .f32x1 = gltf_material.metallic_roughness.metallic_factor,
    };
    var roughness = ImageManager.TextureSource {
        .f32x1 = gltf_material.metallic_roughness.roughness_factor,
    };

    if (gltf_material.metallic_roughness.metallic_roughness_texture) |texture| {
        const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
        std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

        // this gives us rgb --> only need r (metallic) and g (roughness) channels
        // theoretically gltf spec claims these values should already be linear
        var img = try zigimg.Image.fromMemory(allocator, image.data.?);
        defer img.deinit();

        var r = try allocator.alloc(u8, img.pixels.len());
        var g = try allocator.alloc(u8, img.pixels.len());
        for (img.pixels.rgb24) |pixel, i| {
            r[i] = pixel.r;
            g[i] = pixel.g;
        }
        metalness = ImageManager.TextureSource {
            .raw = .{
                .bytes = r,
                .width = @intCast(u32, img.width),
                .height = @intCast(u32, img.height),
                .format = .r8_unorm,
                .layout = .shader_read_only_optimal,
                .usage = .{ .sampled_bit = true },
            },
        };
        roughness = ImageManager.TextureSource {
            .raw = .{
                .bytes = g,
                .width = @intCast(u32, img.width),
                .height = @intCast(u32, img.height),
                .format = .r8_unorm,
                .layout = .shader_read_only_optimal,
                .usage = .{ .sampled_bit = true },
            },
        };
    }

    var normal = ImageManager.TextureSource {
        .f32x2 = F32x2.new(0.5, 0.5),
    };
    if (gltf_material.normal_texture) |texture| {
        const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
        std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

        // this gives us rgb --> need to convert to rg
        // theoretically gltf spec claims these values should already be linear
        var img = try zigimg.Image.fromMemory(allocator, image.data.?);
        defer img.deinit();

        var rg = try allocator.alloc(u8, img.pixels.len() * 2);
        for (img.pixels.rgb24) |pixel, i| {
            rg[i * 2 + 0] = pixel.r;
            rg[i * 2 + 1] = pixel.g;
        }
        normal = ImageManager.TextureSource {
            .raw = .{
                .bytes = rg,
                .width = @intCast(u32, img.width),
                .height = @intCast(u32, img.height),
                .format = .r8g8_unorm,
                .layout = .shader_read_only_optimal,
                .usage = .{ .sampled_bit = true },
            },
        };
    }

    return Material {
        .color = color,
        .metalness = metalness,
        .roughness = roughness,
        .normal = normal,
        .emissive = emissive,
    };
}

fn createDescriptorSet(self: *const Self, vc: *const VulkanContext, allocator: std.mem.Allocator, descriptor_layout: *const SceneDescriptorLayout) !vk.DescriptorSet {
    const image_infos = try allocator.alloc(vk.DescriptorImageInfo, self.material_manager.textures.data.len);
    defer allocator.free(image_infos);

    const texture_views = self.material_manager.textures.data.items(.view);
    for (image_infos) |*info, i| {
        info.* = .{
            .sampler = .null_handle,
            .image_view = texture_views[i],
            .image_layout = .shader_read_only_optimal,
        };
    }

    const descriptor_set = (try descriptor_layout.allocate_sets(vc, 1, [9]vk.WriteDescriptorSet {
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
                .p_acceleration_structures = utils.toPointerType(&self.accel.tlas_handle),
            },
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
                .buffer = self.accel.instance_to_world.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
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
                .buffer = self.accel.world_to_instance.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 3,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
                .buffer = self.mesh_manager.addresses_buffer.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
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
                .buffer = self.accel.mesh_idxs.handle,
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
                .buffer = self.accel.material_idxs.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 6,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .sampler,
            .p_image_info = utils.toPointerType(&vk.DescriptorImageInfo {
                .sampler = self.sampler,
                .image_view = .null_handle,
                .image_layout = undefined,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 7,
            .dst_array_element = 0,
            .descriptor_count = @intCast(u32, image_infos.len),
            .descriptor_type = .sampled_image,
            .p_image_info = image_infos.ptr,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 8,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = utils.toPointerType(&vk.DescriptorBufferInfo {
                .buffer = self.material_manager.values.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
    }))[0];

    try utils.setDebugName(vc, descriptor_set, "Scene");

    return descriptor_set;
}

// TODO: camera
// glTF doesn't correspond very well to the internal data structures here so this is very inefficient
// also very inefficient because it's written very inefficiently, can remove a lot of copying, but that's a problem for another time
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
        std.math.maxInt(usize),
    );
    defer allocator.free(buffer);
    try gltf.parse(buffer);

    // materials
    var material_manager = blk: {
        const materials = try allocator.alloc(Material, gltf.data.materials.items.len);
        defer allocator.free(materials);
        defer for (materials) |material| {
            switch (material.color) {
                .raw => |raw| allocator.free(raw.bytes),
                else => {},
            }
            switch (material.metalness) {
                .raw => |raw| allocator.free(raw.bytes),
                else => {},
            }
            switch (material.roughness) {
                .raw => |raw| allocator.free(raw.bytes),
                else => {},
            }
            switch (material.normal) {
                .raw => |raw| allocator.free(raw.bytes),
                else => {},
            }
            switch (material.emissive) {
                .raw => |raw| allocator.free(raw.bytes),
                else => {},
            }
        };

        for (gltf.data.materials.items) |material, i| {
            materials[i] = try gltfMaterialToMaterial(allocator, gltf, material);
        }

        break :blk try MaterialManager.create(vc, vk_allocator, allocator, commands, materials);
    };
    errdefer material_manager.destroy(vc, allocator);

    // meshes
    // for each gltf mesh we create a model
    // for each gltf primitive we create a mesh
    var objects = std.ArrayList(MeshData).init(allocator);
    defer objects.deinit();
    defer for (objects.items) |*object| object.destroy(allocator);

    const models = try allocator.alloc(Model, gltf.data.meshes.items.len);
    defer allocator.free(models);

    const skins = try allocator.alloc(Skin, gltf.data.meshes.items.len);
    defer allocator.free(skins);

    for (gltf.data.meshes.items) |mesh, model_idx| {
        const mesh_idxs = try allocator.alloc(u32, mesh.primitives.items.len);
        errdefer allocator.free(mesh_idxs);
        const material_idxs = try allocator.alloc(u32, mesh.primitives.items.len);
        errdefer allocator.free(material_idxs);
        for (mesh.primitives.items) |primitive, mesh_idx| {
            mesh_idxs[mesh_idx] = @intCast(u32, objects.items.len);
            material_idxs[mesh_idx] = @intCast(u32, primitive.material.?);
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
                var texcoords = std.ArrayList(f32).init(allocator);
                var normals = std.ArrayList(f32).init(allocator);

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
                        .normal => |accessor_index| {
                            const accessor = gltf.data.accessors.items[accessor_index];
                            gltf.getDataFromBufferView(f32, &normals, accessor, gltf.glb_binary.?);
                        },
                        else => {
                            std.debug.print("{any}\n", .{ attribute });
                            return error.UnhandledAttribute;
                        },
                    }
                }

                const positions_slice = positions.toOwnedSlice();
                const texcoords_slice = texcoords.toOwnedSlice();
                const normals_slice = normals.toOwnedSlice();

                // TODO: remove ptrcast workaround below once ptrcast works on slices
                break :blk2 .{
                    .positions = @ptrCast([*]F32x3, positions_slice.ptr)[0..positions_slice.len / 3],
                    .texcoords = @ptrCast([*]F32x2, texcoords_slice.ptr)[0..texcoords_slice.len / 2],
                    .normals = @ptrCast([*]F32x3, normals_slice.ptr)[0..normals_slice.len / 3],
                };
            };
            errdefer allocator.free(vertices.positions);
            errdefer allocator.free(vertices.texcoords);

            // get vertices
            try objects.append(MeshData {
                .positions = vertices.positions,
                .texcoords = if (vertices.texcoords.len != 0) vertices.texcoords else null,
                .normals = if (vertices.normals.len != 0) vertices.normals else null,
                .indices = indices,
            });
        }
        models[model_idx].mesh_idxs = mesh_idxs;
        skins[model_idx].material_idxs = material_idxs;
    }
    defer for (models) |model| allocator.free(model.mesh_idxs);
    defer for (skins) |skin| allocator.free(skin.material_idxs);

    var mesh_manager = try MeshManager.create(vc, vk_allocator, allocator, commands, objects.items);
    errdefer mesh_manager.destroy(vc, allocator);

    // go over heirarchy, finding meshes
    var instances = blk: {
        var instances = Instances {};
        errdefer instances.deinit(allocator);

        // not most efficient way but simplest and does the trick
        for (gltf.data.nodes.items) |node| {
            if (node.mesh) |model_idx| {
                const mat = Gltf.getGlobalTransform(&gltf.data, node);
                try instances.append(allocator, .{
                    .transform = Mat3x4.new(
                        F32x4.new(mat[0][0], mat[1][0], mat[2][0], mat[3][0]),
                        F32x4.new(mat[0][1], mat[1][1], mat[2][1], mat[3][1]),
                        F32x4.new(mat[0][2], mat[1][2], mat[2][2], mat[3][2]),
                    ),
                    .model_idx = @intCast(u12, model_idx),
                    .skin_idx = @intCast(u12, model_idx),
                });
            }
        }

        break :blk instances;
    };
    defer instances.deinit(allocator);

    var accel = try Accel.create(vc, vk_allocator, allocator, commands, mesh_manager, instances, models, skins);
    errdefer accel.destroy(vc, allocator);

    var scene = Self {
        .background = background,

        .material_manager = material_manager,
        .mesh_manager = mesh_manager,

        .accel = accel,

        .sampler = sampler,
        .descriptor_set = undefined,
    };

    scene.descriptor_set = try scene.createDescriptorSet(vc, allocator, descriptor_layout);

    return scene;
}

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, materials: []const Material, background_dir: []const u8, mesh_filepaths: []const []const u8, instances: Instances, models: []const Model, skins: []const Skin, descriptor_layout: *const SceneDescriptorLayout, background_descriptor_layout: *const BackgroundDescriptorLayout) !Self {
    var material_manager = try MaterialManager.create(vc, vk_allocator, allocator, commands, materials);
    errdefer material_manager.destroy(vc, allocator);

    const image_infos = try allocator.alloc(vk.DescriptorImageInfo, materials.len * Material.textures_per_material);
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

    var accel = try Accel.create(vc, vk_allocator, allocator, commands, mesh_manager, instances, models, skins);
    errdefer accel.destroy(vc, allocator);

    const sampler = try ImageManager.createSampler(vc);

    const background = try Background.create(vc, vk_allocator, allocator, commands, background_dir, background_descriptor_layout, sampler);

    var scene = Self {
        .background = background,

        .material_manager = material_manager,
        .mesh_manager = mesh_manager,

        .accel = accel,

        .sampler = sampler,
        .descriptor_set = undefined,
    };

    scene.descriptor_set = try scene.createDescriptorSet(vc, allocator, descriptor_layout);

    return scene;
}

pub fn updateTransform(self: *Self, index: u32, new_transform: Mat3x4) void {
    self.accel.updateTransform(index, new_transform);
}

pub fn updateVisibility(self: *Self, index: u32, visible: bool) void {
    self.accel.updateVisibility(index, visible);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    vc.device.destroySampler(self.sampler, null);

    self.background.destroy(vc, allocator);
    self.material_manager.destroy(vc, allocator);
    self.mesh_manager.destroy(vc, allocator);
    self.accel.destroy(vc, allocator);
}
