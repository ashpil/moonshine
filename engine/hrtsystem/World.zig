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

const MaterialManager = engine.hrtsystem.MaterialManager;
const TextureManager = MaterialManager.TextureManager;

const MeshManager = engine.hrtsystem.MeshManager;
const Accel = engine.hrtsystem.Accel;

const vector = engine.vector;
const Mat3x4 = vector.Mat3x4(f32);
const F32x4 = vector.Vec4(f32);
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);
const U32x3 = vector.Vec3(u32);

pub const Material = MaterialManager.MaterialInfo;
pub const MaterialVariant = MaterialManager.MaterialVariant;
pub const Instance = Accel.Instance;
pub const Geometry = Accel.Geometry;

// must be kept in sync with shader
const max_textures = 20 * 5; // TODO: think about this more, really really should
pub const DescriptorLayout = core.descriptor.DescriptorLayout(&.{
    .{ // TLAS
        .descriptor_type = .acceleration_structure_khr,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // instances
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // worldToInstance
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // emitterAliasTable
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // meshes
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // geometries
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // materialValues
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
}, .{}, 2, "World");

materials: MaterialManager,

meshes: MeshManager,
accel: Accel,

descriptor_layout: DescriptorLayout,
descriptor_set: vk.DescriptorSet,

const Self = @This();

// TODO: consider just uploading all textures upfront rather than as part of this function
fn gltfMaterialToMaterial(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, gltf: Gltf, gltf_material: Gltf.Material, textures: *TextureManager) !Material {
    // stuff that is in every material
    var material = blk: {
        var material: Material = undefined;
        material.normal = if (gltf_material.normal_texture) |texture| normal: {
            const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
            std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

            // this gives us rgb --> need to convert to rg
            // theoretically gltf spec claims these values should already be linear
            var img = try zigimg.Image.fromMemory(allocator, image.data.?);
            defer img.deinit();

            var rg = try allocator.alloc(u8, img.pixels.len() * 2);
            defer allocator.free(rg);
            for (img.pixels.rgb24, 0..) |pixel, i| {
                rg[i * 2 + 0] = pixel.r;
                rg[i * 2 + 1] = pixel.g;
            }
            const debug_name = try std.fmt.allocPrintZ(allocator, "{s} normal", .{ gltf_material.name });
            defer allocator.free(debug_name);
            break :normal try textures.upload(vc, vk_allocator, allocator, commands, TextureManager.Source {
                .raw = .{
                    .bytes = rg,
                    .extent = vk.Extent2D {
                        .width = @intCast(img.width),
                        .height = @intCast(img.height),
                    },
                    .format = .r8g8_unorm,
                },
            }, debug_name);
        } else try textures.upload(vc, vk_allocator, allocator, commands, TextureManager.Source {
            .f32x2 = Material.default_normal,
        }, "default normal");
        
        material.emissive = if (gltf_material.emissive_texture) |texture| emissive: {
            const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
            std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

            // this gives us rgb --> need to convert to rgba
            var img = try zigimg.Image.fromMemory(allocator, image.data.?);
            defer img.deinit();

            var rgba = try zigimg.color.PixelStorage.init(allocator, .rgba32, img.pixels.len());
            defer rgba.deinit(allocator);
            for (img.pixels.rgb24, rgba.rgba32) |pixel, *rgba32| {
                rgba32.* = zigimg.color.Rgba32.initRgba(pixel.r, pixel.g, pixel.b, std.math.maxInt(u8));
            }
            const debug_name = try std.fmt.allocPrintZ(allocator, "{s} emissive", .{ gltf_material.name });
            defer allocator.free(debug_name);
            break :emissive try textures.upload(vc, vk_allocator, allocator, commands, TextureManager.Source {
                .raw = .{
                    .bytes = rgba.asBytes(),
                    .extent = vk.Extent2D {
                        .width = @intCast(img.width),
                        .height = @intCast(img.height),
                    },
                    .format = .r8g8b8a8_srgb,
                },
            }, debug_name);
        } else emissive: {
            const constant = F32x3.new(gltf_material.emissive_factor[0], gltf_material.emissive_factor[1], gltf_material.emissive_factor[2]).mul_scalar(gltf_material.emissive_strength);
            const debug_name = try std.fmt.allocPrintZ(allocator, "{s} constant emissive {}", .{ gltf_material.name, constant });
            defer allocator.free(debug_name);
            break :emissive try textures.upload(vc, vk_allocator, allocator, commands, TextureManager.Source {
                .f32x3 = constant,
            }, debug_name);
        };
        
        break :blk material;
    };

    var standard_pbr: MaterialManager.StandardPBR = undefined;
    standard_pbr.ior = gltf_material.ior;

    if (gltf_material.transmission_factor == 1.0) {
        material.variant = .{ .glass = .{ .ior = standard_pbr.ior } };
        return material;
    }

    standard_pbr.color = if (gltf_material.metallic_roughness.base_color_texture) |texture| blk: {
        const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
        std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

        // this gives us rgb --> need to convert to rgba
        var img = try zigimg.Image.fromMemory(allocator, image.data.?);
        defer img.deinit();

        var rgba = try zigimg.color.PixelStorage.init(allocator, .rgba32, img.pixels.len());
        defer rgba.deinit(allocator);
        for (img.pixels.rgb24, rgba.rgba32) |pixel, *rgba32| {
            rgba32.* = zigimg.color.Rgba32.initRgba(pixel.r, pixel.g, pixel.b, std.math.maxInt(u8));
        }
        const debug_name = try std.fmt.allocPrintZ(allocator, "{s} color", .{ gltf_material.name });
        defer allocator.free(debug_name);
        break :blk try textures.upload(vc, vk_allocator, allocator, commands, TextureManager.Source {
            .raw = .{
                .bytes = rgba.asBytes(),
                .extent = vk.Extent2D {
                    .width = @intCast(img.width),
                    .height = @intCast(img.height),
                },
                .format = .r8g8b8a8_srgb,
            },
        }, debug_name);
    } else blk: {
        const constant = F32x3.new(gltf_material.metallic_roughness.base_color_factor[0], gltf_material.metallic_roughness.base_color_factor[1], gltf_material.metallic_roughness.base_color_factor[2]);
        const debug_name = try std.fmt.allocPrintZ(allocator, "{s} constant color {}", .{ gltf_material.name, constant });
        defer allocator.free(debug_name);
        break :blk try textures.upload(vc, vk_allocator, allocator, commands, TextureManager.Source {
            .f32x3 = F32x3.new(gltf_material.metallic_roughness.base_color_factor[0], gltf_material.metallic_roughness.base_color_factor[1], gltf_material.metallic_roughness.base_color_factor[2])
        }, debug_name);
    };

    if (gltf_material.metallic_roughness.metallic_roughness_texture) |texture| {
        const image = gltf.data.images.items[gltf.data.textures.items[texture.index].source.?];
        std.debug.assert(std.mem.eql(u8, image.mime_type.?, "image/png"));

        // this gives us rgb --> only need r (metallic) and g (roughness) channels
        // theoretically gltf spec claims these values should already be linear
        var img = try zigimg.Image.fromMemory(allocator, image.data.?);
        defer img.deinit();

        const rs = try allocator.alloc(u8, img.pixels.len());
        defer allocator.free(rs);
        const gs = try allocator.alloc(u8, img.pixels.len());
        defer allocator.free(gs);
        for (img.pixels.rgb24, rs, gs) |pixel, *r, *g| {
            r.* = pixel.r;
            g.* = pixel.g;
        }
        const debug_name_metalness = try std.fmt.allocPrintZ(allocator, "{s} metalness", .{ gltf_material.name });
        defer allocator.free(debug_name_metalness);
        standard_pbr.metalness = try textures.upload(vc, vk_allocator, allocator, commands, TextureManager.Source {
            .raw = .{
                .bytes = rs,
                .extent = vk.Extent2D {
                    .width = @intCast(img.width),
                    .height = @intCast(img.height),
                },
                .format = .r8_unorm,
            },
        }, debug_name_metalness);
        const debug_name_roughness = try std.fmt.allocPrintZ(allocator, "{s} roughness", .{ gltf_material.name });
        defer allocator.free(debug_name_roughness);
        standard_pbr.roughness = try textures.upload(vc, vk_allocator, allocator, commands, TextureManager.Source {
            .raw = .{
                .bytes = gs,
                .extent = vk.Extent2D {
                    .width = @intCast(img.width),
                    .height = @intCast(img.height),
                },
                .format = .r8_unorm,
            },
        }, debug_name_roughness);
        material.variant = .{ .standard_pbr = standard_pbr };
        return material;
    } else {
        if (gltf_material.metallic_roughness.metallic_factor == 0.0 and gltf_material.metallic_roughness.roughness_factor == 1.0) {
            // parse as lambert
            const lambert = MaterialManager.Lambert {
                .color = standard_pbr.color,
            };
            material.variant = .{ .lambert = lambert };
            return material;
        } else if (gltf_material.metallic_roughness.metallic_factor == 1.0 and gltf_material.metallic_roughness.roughness_factor == 0.0) {
            // parse as perfect mirror
            material.variant = .{ .perfect_mirror = {} };
            return material;
        } else {
            const debug_name_metalness = try std.fmt.allocPrintZ(allocator, "{s} constant metalness {}", .{ gltf_material.name, gltf_material.metallic_roughness.metallic_factor });
            defer allocator.free(debug_name_metalness);
            standard_pbr.metalness = try textures.upload(vc, vk_allocator, allocator, commands, TextureManager.Source {
                .f32x1 = gltf_material.metallic_roughness.metallic_factor,
            }, debug_name_metalness);
            const debug_name_roughness = try std.fmt.allocPrintZ(allocator, "{s} constant debug_name_roughness {}", .{ gltf_material.name, gltf_material.metallic_roughness.roughness_factor });
            defer allocator.free(debug_name_roughness);
            standard_pbr.roughness = try textures.upload(vc, vk_allocator, allocator, commands, TextureManager.Source {
                .f32x1 = gltf_material.metallic_roughness.roughness_factor,
            }, debug_name_roughness);
            material.variant = .{ .standard_pbr = standard_pbr };
            return material;
        }
    }
}

pub fn createDescriptorSet(self: *Self, vc: *const VulkanContext) !void {
    const descriptor_set = try self.descriptor_layout.allocate_set(vc, [_]vk.WriteDescriptorSet {
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
                .buffer = self.meshes.addresses_buffer.handle,
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
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = self.materials.materials.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
    });

    try vk_helpers.setDebugName(vc, descriptor_set, "World");

    self.descriptor_set = descriptor_set;
}

// glTF doesn't correspond very well to the internal data structures here so this is very inefficient
// also very inefficient because it's written very inefficiently, can remove a lot of copying, but that's a problem for another time
// inspection bool specifies whether some buffers should be created with the `transfer_src_flag` for inspection
pub fn fromGlb(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, gltf: Gltf, inspection: bool) !Self {
    var materials = blk: {
        var material_list = std.ArrayListUnmanaged(MaterialManager.MaterialInfo) {};
        defer material_list.deinit(allocator);

        var textures = try TextureManager.create(vc);

        for (gltf.data.materials.items) |material| {
            const mat = try gltfMaterialToMaterial(vc, vk_allocator, allocator, commands, gltf, material, &textures);
            try material_list.append(allocator, mat);
        }

        var materials = try MaterialManager.create(vc, vk_allocator, allocator, commands, material_list.items);
        materials.textures.destroy(vc, allocator); // strange
        materials.textures = textures;

        break :blk materials; 
    };
    errdefer materials.destroy(vc, allocator);

    var objects = std.ArrayList(MeshManager.Mesh).init(allocator);
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
                    const actual_indices = try allocator.alloc(U32x3, indices.items.len / 3);
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
                try objects.append(MeshManager.Mesh {
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

    var meshes = try MeshManager.create(vc, vk_allocator, allocator, commands, objects.items);
    errdefer meshes.destroy(vc, allocator);

    var accel = try Accel.create(vc, vk_allocator, allocator, commands, meshes, instances.items, inspection);
    errdefer accel.destroy(vc, allocator);

    var descriptor_layout = try DescriptorLayout.create(vc, .{});
    errdefer descriptor_layout.destroy(vc);

    var world = Self {
        .materials = materials,
        .meshes = meshes,

        .accel = accel,

        .descriptor_set = undefined,
        .descriptor_layout = descriptor_layout,
    };
    try world.createDescriptorSet(vc);

    return world;
}

pub fn createEmpty(vc: *const VulkanContext) !Self {
    var self = Self {
        .materials = try MaterialManager.createEmpty(vc),
        .meshes = .{},
        .accel = .{},

        .descriptor_layout = try DescriptorLayout.create(vc, .{}),
        .descriptor_set = undefined,
    };
    try self.createDescriptorSet(vc);
    return self;
}

pub fn updateTransform(self: *Self, index: u32, new_transform: Mat3x4) void {
    self.accel.updateTransform(index, new_transform);
}

pub fn updateVisibility(self: *Self, index: u32, visible: bool) void {
    self.accel.updateVisibility(index, visible);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.materials.destroy(vc, allocator);
    self.meshes.destroy(vc, allocator);
    self.accel.destroy(vc, allocator);

    self.descriptor_layout.destroy(vc);
}
