// a world contains:
// - a list of meshes
// - an acceleration structure/mesh heirarchy
// - materials

const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");
const zigimg = @import("zigimg");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Commands = core.Commands;
const VkAllocator = core.Allocator;
const vk_helpers = core.vk_helpers;
const ImageManager = core.ImageManager;

const MsneReader = engine.fileformats.msne.MsneReader;

const MeshData = @import("./Object.zig");
const MaterialManager = @import("./MaterialManager.zig");

const MeshManager = @import("./MeshManager.zig");
const Accel = @import("./Accel.zig");

const vector = engine.vector;
const Mat3x4 = vector.Mat3x4(f32);
const F32x4 = vector.Vec4(f32);
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);
const U32x3 = vector.Vec3(u32);

pub const Material = MaterialManager.Material;
pub const AnyMaterial = MaterialManager.AnyMaterial;
pub const Instance = Accel.Instance;
pub const Geometry = Accel.Geometry;

// must be kept in sync with shader
const max_textures = 20 * 5; // TODO: think about this more, really really should
pub const DescriptorLayout = core.descriptor.DescriptorLayout(&.{
    .{ // TLAS
        .binding = 0,
        .descriptor_type = .acceleration_structure_khr,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // instances
        .binding = 1,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // worldToInstance
        .binding = 2,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // emitterAliasTable
        .binding = 3,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // meshes
        .binding = 4,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // geometries
        .binding = 5,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // textureSampler
        .binding = 6,
        .descriptor_type = .sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // materialTextures
        .binding = 7,
        .descriptor_type = .sampled_image,
        .descriptor_count = max_textures,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
    .{ // materialValues
        .binding = 8,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .p_immutable_samplers = null,
    },
}, .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{ .partially_bound_bit = true }, .{}, }, "World");

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
        material.normal = @intCast(textures.items.len);
        material.type = .standard_pbr;
        if (gltf_material.normal_texture) |texture| {
            const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
            std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

            // this gives us rgb --> need to convert to rg
            // theoretically gltf spec claims these values should already be linear
            var img = try zigimg.Image.fromMemory(allocator, image.data.?);
            defer img.deinit();

            var rg = try allocator.alloc(u8, img.pixels.len() * 2);
            for (img.pixels.rgb24, 0..) |pixel, i| {
                rg[i * 2 + 0] = pixel.r;
                rg[i * 2 + 1] = pixel.g;
            }
            try textures.append(ImageManager.TextureSource {
                .raw = .{
                    .bytes = rg,
                    .extent = vk.Extent2D {
                        .width = @intCast(img.width),
                        .height = @intCast(img.height),
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

        material.emissive = @intCast(textures.items.len);
        if (gltf_material.emissive_texture) |texture| {
            const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
            std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

            // this gives us rgb --> need to convert to rgba
            var img = try zigimg.Image.fromMemory(allocator, image.data.?);
            defer img.deinit();

            var rgba = try zigimg.color.PixelStorage.init(allocator, .rgba32, img.pixels.len());
            for (img.pixels.rgb24, rgba.rgba32) |pixel, *rgba32| {
                rgba32.* = zigimg.color.Rgba32.initRgba(pixel.r, pixel.g, pixel.b, std.math.maxInt(u8));
            }
            try textures.append(ImageManager.TextureSource {
                .raw = .{
                    .bytes = rgba.asBytes(),
                    .extent = vk.Extent2D {
                        .width = @intCast(img.width),
                        .height = @intCast(img.height),
                    },
                    .format = .r8g8b8a8_srgb,
                    .layout = .shader_read_only_optimal,
                    .usage = .{ .sampled_bit = true },
                },
            });
        } else {
            try textures.append(ImageManager.TextureSource {
                .f32x3 = F32x3.new(gltf_material.emissive_factor[0], gltf_material.emissive_factor[1], gltf_material.emissive_factor[2]).mul_scalar(gltf_material.emissive_strength),
            });
        }
        
        break :blk material;
    };

    var standard_pbr: MaterialManager.StandardPBR = undefined;
    standard_pbr.ior = gltf_material.ior;

    if (gltf_material.transmission_factor == 1.0) {
        return .{ material, .{ .glass = .{ .ior = standard_pbr.ior } } };
    }

    standard_pbr.color = @intCast(textures.items.len);
    if (gltf_material.metallic_roughness.base_color_texture) |texture| {
        const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
        std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

        // this gives us rgb --> need to convert to rgba
        var img = try zigimg.Image.fromMemory(allocator, image.data.?);
        defer img.deinit();

        var rgba = try zigimg.color.PixelStorage.init(allocator, .rgba32, img.pixels.len());
        for (img.pixels.rgb24, rgba.rgba32) |pixel, *rgba32| {
            rgba32.* = zigimg.color.Rgba32.initRgba(pixel.r, pixel.g, pixel.b, std.math.maxInt(u8));
        }
        try textures.append(ImageManager.TextureSource {
            .raw = .{
                .bytes = rgba.asBytes(),
                .extent = vk.Extent2D {
                    .width = @intCast(img.width),
                    .height = @intCast(img.height),
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

    standard_pbr.metalness = @intCast(textures.items.len);
    standard_pbr.roughness = @intCast(textures.items.len + 1);
    if (gltf_material.metallic_roughness.metallic_roughness_texture) |texture| {
        const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
        std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

        // this gives us rgb --> only need r (metallic) and g (roughness) channels
        // theoretically gltf spec claims these values should already be linear
        var img = try zigimg.Image.fromMemory(allocator, image.data.?);
        defer img.deinit();

        var rs = try allocator.alloc(u8, img.pixels.len());
        var gs = try allocator.alloc(u8, img.pixels.len());
        for (img.pixels.rgb24, rs, gs) |pixel, *r, *g| {
            r.* = pixel.r;
            g.* = pixel.g;
        }
        try textures.append(ImageManager.TextureSource {
            .raw = .{
                .bytes = rs,
                .extent = vk.Extent2D {
                    .width = @intCast(img.width),
                    .height = @intCast(img.height),
                },
                .format = .r8_unorm,
                .layout = .shader_read_only_optimal,
                .usage = .{ .sampled_bit = true },
            },
        });
        try textures.append(ImageManager.TextureSource {
            .raw = .{
                .bytes = gs,
                .extent = vk.Extent2D {
                    .width = @intCast(img.width),
                    .height = @intCast(img.height),
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
        } else if (gltf_material.metallic_roughness.metallic_factor == 1.0 and gltf_material.metallic_roughness.roughness_factor == 0.0) {
            // parse as perfect mirror
            return .{ material, .{ .perfect_mirror = {} } };
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

fn createDescriptorSet(self: *const Self, vc: *const VulkanContext, allocator: std.mem.Allocator, descriptor_layout: *const DescriptorLayout) !vk.DescriptorSet {
    const image_infos = try allocator.alloc(vk.DescriptorImageInfo, self.material_manager.textures.data.len);
    defer allocator.free(image_infos);

    const texture_views = self.material_manager.textures.data.items(.view);
    for (image_infos, texture_views) |*info, texture_view| {
        info.* = .{
            .sampler = .null_handle,
            .image_view = texture_view,
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
                .p_acceleration_structures = @ptrCast(&self.accel.tlas_handle),
            },
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
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
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
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
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
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
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
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
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
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
            .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
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
            .descriptor_count = @intCast(image_infos.len),
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
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = self.material_manager.materials.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
    });

    try vk_helpers.setDebugName(vc, descriptor_set, "World");

    return descriptor_set;
}

// glTF doesn't correspond very well to the internal data structures here so this is very inefficient
// also very inefficient because it's written very inefficiently, can remove a lot of copying, but that's a problem for another time
// inspection bool specifies whether some buffers should be created with the `transfer_src_flag` for inspection
pub fn fromGlb(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, descriptor_layout: *const DescriptorLayout, gltf: Gltf, inspection: bool) !Self {
    const sampler = try ImageManager.createSampler(vc);

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

        break :blk try MaterialManager.create(vc, vk_allocator, allocator, commands, textures.items, material_list, inspection);
    };
    errdefer material_manager.destroy(vc, allocator);

    var objects = std.ArrayList(MeshData).init(allocator);
    defer objects.deinit();
    defer for (objects.items) |*object| object.destroy(allocator);

    // go over heirarchy, finding meshes
    var instances = std.ArrayList(Instance).init(allocator);
    defer instances.deinit();
    defer for (instances.items) |instance| allocator.free(instance.geometries);

    for (gltf.data.nodes.items) |node| {
        if (node.mesh) |model_idx| {
            const mesh = gltf.data.meshes.items[model_idx];
            const geometries = try allocator.alloc(Geometry, mesh.primitives.items.len);
            for (mesh.primitives.items, geometries) |primitive, *geometry| {
                geometry.* = Geometry {
                    .mesh = @intCast(objects.items.len),
                    .material = @intCast(primitive.material.?),
                    .sampled = std.mem.startsWith(u8, gltf.data.materials.items[primitive.material.?].name, "Emitter"),
                };
                // get indices
                const indices = blk2: {
                    var indices = std.ArrayList(u16).init(allocator);
                    defer indices.deinit();

                    const accessor = gltf.data.accessors.items[primitive.indices.?];
                    gltf.getDataFromBufferView(u16, &indices, accessor, gltf.glb_binary.?);

                    // convert to U32x3
                    var actual_indices = try allocator.alloc(U32x3, indices.items.len / 3);
                    for (actual_indices, 0..) |*index, i| {
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
                        .positions = @as([*]F32x3, @ptrCast(positions_slice.ptr))[0..positions_slice.len / 3],
                        .texcoords = @as([*]F32x2, @ptrCast(texcoords_slice.ptr))[0..texcoords_slice.len / 2],
                        .normals = @as([*]F32x3, @ptrCast(normals_slice.ptr))[0..normals_slice.len / 3],
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

            const mat = Gltf.getGlobalTransform(&gltf.data, node);
            // convert to Z-up
            try instances.append(Instance {
                .transform = Mat3x4.new(
                    F32x4.new(mat[0][0], mat[1][0], mat[2][0], mat[3][0]),
                    F32x4.new(mat[0][2], mat[1][2], mat[2][2], mat[3][2]),
                    F32x4.new(mat[0][1], mat[1][1], mat[2][1], mat[3][1]),
                ),
                .geometries = geometries,
            });
        }
    }

    var mesh_manager = try MeshManager.create(vc, vk_allocator, allocator, commands, objects.items);
    errdefer mesh_manager.destroy(vc, allocator);

    var accel = try Accel.create(vc, vk_allocator, allocator, commands, mesh_manager, instances.items, inspection);
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

pub fn fromMsne(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, descriptor_layout: *const DescriptorLayout, msne_reader: MsneReader, inspection: bool) !Self {
    var material_manager = try MaterialManager.fromMsne(vc, vk_allocator, allocator, commands, msne_reader, inspection);
    errdefer material_manager.destroy(vc, allocator);

    var mesh_manager = try MeshManager.fromMsne(vc, vk_allocator, allocator, commands, msne_reader);
    errdefer mesh_manager.destroy(vc, allocator);

    var accel = try Accel.fromMsne(vc, vk_allocator, allocator, commands, mesh_manager, msne_reader, inspection);
    errdefer accel.destroy(vc, allocator);

    var world = Self {
        .material_manager = material_manager,
        .mesh_manager = mesh_manager,

        .accel = accel,

        .sampler = try ImageManager.createSampler(vc),
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
