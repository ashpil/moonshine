// a world contains:
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
const WorldDescriptorLayout = descriptor.WorldDescriptorLayout;
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
pub const AnyMaterial = MaterialManager.AnyMaterial;
pub const Instances = Accel.InstanceInfos;
pub const MeshGroup = Accel.MeshGroup;

material_manager: MaterialManager,

mesh_manager: MeshManager,
accel: Accel,

sampler: vk.Sampler,
descriptor_set: vk.DescriptorSet,

const Self = @This();

fn gltfMaterialToMaterial(allocator: std.mem.Allocator, gltf: Gltf, gltf_material: Gltf.Material, textures: *std.ArrayList(ImageManager.TextureSource)) !std.meta.Tuple(&.{ Material, AnyMaterial }) {
    // stuff that is in every material
    const material = blk: {
        var material: Material = undefined;
        material.normal = @intCast(u32, textures.items.len);
        material.type = .standard_pbr;
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
            try textures.append(ImageManager.TextureSource {
                .raw = .{
                    .bytes = rg,
                    .extent = vk.Extent2D {
                        .width = @intCast(u32, img.width),
                        .height = @intCast(u32, img.height),
                    },
                    .format = .r8g8_unorm,
                    .layout = .shader_read_only_optimal,
                    .usage = .{ .sampled_bit = true },
                },
            });
        } else {
            try textures.append(ImageManager.TextureSource {
                .f32x2 = F32x2.new(0.5, 0.5),
            });
        }

        material.emissive = @intCast(u32, textures.items.len);
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
            try textures.append(ImageManager.TextureSource {
                .raw = .{
                    .bytes = rgba.asBytes(),
                    .extent = vk.Extent2D {
                        .width = @intCast(u32, img.width),
                        .height = @intCast(u32, img.height),
                    },
                    .format = .r8g8b8a8_srgb,
                    .layout = .shader_read_only_optimal,
                    .usage = .{ .sampled_bit = true },
                },
            });
        } else {
            try textures.append(ImageManager.TextureSource {
                .f32x3 = F32x3.new(gltf_material.emissive_factor[0], gltf_material.emissive_factor[1], gltf_material.emissive_factor[2]),
            });
        }
        
        break :blk material;
    };



    var standard_pbr: MaterialManager.StandardPBR = undefined;
    standard_pbr.ior = 1.5;
    standard_pbr.color = @intCast(u32, textures.items.len);
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
        try textures.append(ImageManager.TextureSource {
            .raw = .{
                .bytes = rgba.asBytes(),
                .extent = vk.Extent2D {
                    .width = @intCast(u32, img.width),
                    .height = @intCast(u32, img.height),
                },
                .format = .r8g8b8a8_srgb,
                .layout = .shader_read_only_optimal,
                .usage = .{ .sampled_bit = true },
            },
        });
    } else {
        try textures.append(ImageManager.TextureSource {
            .f32x3 = F32x3.new(gltf_material.metallic_roughness.base_color_factor[0], gltf_material.metallic_roughness.base_color_factor[1], gltf_material.metallic_roughness.base_color_factor[2])
        });
    }

    standard_pbr.metalness = @intCast(u32, textures.items.len);
    standard_pbr.roughness = @intCast(u32, textures.items.len + 1);
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
        try textures.append(ImageManager.TextureSource {
            .raw = .{
                .bytes = r,
                .extent = vk.Extent2D {
                    .width = @intCast(u32, img.width),
                    .height = @intCast(u32, img.height),
                },
                .format = .r8_unorm,
                .layout = .shader_read_only_optimal,
                .usage = .{ .sampled_bit = true },
            },
        });
        try textures.append(ImageManager.TextureSource {
            .raw = .{
                .bytes = g,
                .extent = vk.Extent2D {
                    .width = @intCast(u32, img.width),
                    .height = @intCast(u32, img.height),
                },
                .format = .r8_unorm,
                .layout = .shader_read_only_optimal,
                .usage = .{ .sampled_bit = true },
            },
        });
        return .{ material, .{ .standard_pbr = standard_pbr } };
    } else {
        if (gltf_material.metallic_roughness.metallic_factor == 0.0 and gltf_material.metallic_roughness.roughness_factor == 1.0) {
            // parse as lambert
            const lambert = MaterialManager.Lambert {
                .color = standard_pbr.color,
            };
            return .{ material, .{ .lambert = lambert } };
        } else {
            try textures.append(ImageManager.TextureSource {
                .f32x1 = gltf_material.metallic_roughness.metallic_factor,
            });
            try textures.append(ImageManager.TextureSource {
                .f32x1 = gltf_material.metallic_roughness.roughness_factor,
            });
            return .{ material, .{ .standard_pbr = standard_pbr } };
        }
    }
}

fn createDescriptorSet(self: *const Self, vc: *const VulkanContext, allocator: std.mem.Allocator, descriptor_layout: *const WorldDescriptorLayout) !vk.DescriptorSet {
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

    const descriptor_set = try descriptor_layout.allocate_set(vc, [9]vk.WriteDescriptorSet {
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
                .buffer = self.accel.instances_device.handle,
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
                .buffer = self.accel.alias_table.handle,
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
                .buffer = self.mesh_manager.addresses_buffer.handle,
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
                .buffer = self.accel.geometries.handle,
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
                .buffer = self.material_manager.materials.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
    });

    try utils.setDebugName(vc, descriptor_set, "World");

    return descriptor_set;
}

// glTF doesn't correspond very well to the internal data structures here so this is very inefficient
// also very inefficient because it's written very inefficiently, can remove a lot of copying, but that's a problem for another time
pub fn fromGlb(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, descriptor_layout: *const WorldDescriptorLayout, filepath: []const u8) !Self {
    const sampler = try ImageManager.createSampler(vc);

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
        var material_list = MaterialManager.MaterialList {};
        defer material_list.destroy(allocator);

        var textures = std.ArrayList(ImageManager.TextureSource).init(allocator);
        defer textures.deinit();
        defer for (textures.items) |texture| {
            if (texture == .raw) {
                allocator.free(texture.raw.bytes);
            }
        };

        for (gltf.data.materials.items) |material| {
            const mat_spbr = try gltfMaterialToMaterial(allocator, gltf, material, &textures);
            try material_list.append(allocator, mat_spbr[0], mat_spbr[1]);
        }

        break :blk try MaterialManager.create(vc, vk_allocator, allocator, commands, textures.items, material_list);
    };
    errdefer material_manager.destroy(vc, allocator);

    // meshes
    // for each gltf mesh we create a mesh group
    // for each gltf primitive we create a mesh
    var objects = std.ArrayList(MeshData).init(allocator);
    defer objects.deinit();
    defer for (objects.items) |*object| object.destroy(allocator);

    const mesh_groups = try allocator.alloc(MeshGroup, gltf.data.meshes.items.len);
    defer allocator.free(mesh_groups);

    const skins = try allocator.alloc([]u32, gltf.data.meshes.items.len);
    defer allocator.free(skins);

    for (gltf.data.meshes.items) |mesh, group_idx| {
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

                const positions_slice = try positions.toOwnedSlice();
                const texcoords_slice = try texcoords.toOwnedSlice();
                const normals_slice = try normals.toOwnedSlice();

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
        mesh_groups[group_idx].meshes = mesh_idxs;
        skins[group_idx] = material_idxs;
    }
    defer for (mesh_groups) |group| allocator.free(group.meshes);
    defer for (skins) |skin| allocator.free(skin);

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
                    .mesh_group = @intCast(u24, model_idx),
                    .materials = skins[model_idx],
                    .sampled_geometry = if (std.mem.startsWith(u8, gltf.data.materials.items[gltf.data.meshes.items[model_idx].primitives.items[0].material.?].name, "Emitter")) &.{ true } else &.{}, // workaround for gltf not supporting this interface
                });
            }
        }

        break :blk instances;
    };
    defer instances.deinit(allocator);

    var accel = try Accel.create(vc, vk_allocator, allocator, commands, mesh_manager, instances, mesh_groups);
    errdefer accel.destroy(vc, allocator);

    var world = Self {
        .material_manager = material_manager,
        .mesh_manager = mesh_manager,

        .accel = accel,

        .sampler = sampler,
        .descriptor_set = undefined,
    };

    world.descriptor_set = try world.createDescriptorSet(vc, allocator, descriptor_layout);

    return world;
}

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, textures: []const ImageManager.TextureSource, materials: []const Material, mesh_filepaths: []const []const u8, instances: Instances, models: []const MeshGroup, descriptor_layout: *const WorldDescriptorLayout) !Self {
    var material_manager = try MaterialManager.create(vc, vk_allocator, allocator, commands, textures, materials);
    errdefer material_manager.destroy(vc, allocator);

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

    var accel = try Accel.create(vc, vk_allocator, allocator, commands, mesh_manager, instances, models);
    errdefer accel.destroy(vc, allocator);

    const sampler = try ImageManager.createSampler(vc);

    var world = Self {
        .material_manager = material_manager,
        .mesh_manager = mesh_manager,

        .accel = accel,

        .sampler = sampler,
        .descriptor_set = undefined,
    };

    world.descriptor_set = try world.createDescriptorSet(vc, allocator, descriptor_layout);

    return world;
}

pub fn updateTransform(self: *Self, index: u32, new_transform: Mat3x4) void {
    self.accel.updateTransform(index, new_transform);
}

pub fn updateVisibility(self: *Self, index: u32, visible: bool) void {
    self.accel.updateVisibility(index, visible);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    vc.device.destroySampler(self.sampler, null);

    self.material_manager.destroy(vc, allocator);
    self.mesh_manager.destroy(vc, allocator);
    self.accel.destroy(vc, allocator);
}
