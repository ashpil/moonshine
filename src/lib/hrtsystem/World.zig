// a world contains:
// - meshes
// - materials
// - an acceleration structure/mesh heirarchy

const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf").Gltf;

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const vk_helpers = core.vk_helpers;

const MaterialManager = engine.hrtsystem.MaterialManager;
const TextureManager = MaterialManager.TextureManager;
const MeshManager = engine.hrtsystem.MeshManager;
const ModelManager = engine.hrtsystem.ModelManager;

const Accel = engine.hrtsystem.Accel;
const ConstantSpectra = engine.hrtsystem.ConstantSpectra;

const vector = engine.vector;
const Mat4 = vector.Mat4(f32);
const Mat4x3 = vector.Mat4x3(f32);
const F32x4 = vector.Vec4(f32);
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);
const U32x3 = vector.Vec3(u32);
const U16x3 = vector.Vec3(u16);
const U8x2 = vector.Vec2(u8);
const U8x3 = vector.Vec3(u8);
const U8x4 = vector.Vec4(u8);

pub const Material = MaterialManager.Material;
pub const PolymorphicBSDF = MaterialManager.PolymorphicBSDF;
pub const Instance = Accel.Instance;
pub const Geometry = ModelManager.Geometry;

meshes: MeshManager,
materials: MaterialManager,
models: ModelManager,

accel: Accel,

constant_spectra: ConstantSpectra,

const Self = @This();

fn loadImage(allocator: std.mem.Allocator, image: Gltf.Image, gltf_directory: ?[]const u8) !std.meta.Tuple(&.{[]const U8x3, u32, u32}) {
    const buffer, const free = if (image.data) |data| .{data, false} else if (image.uri) |uri| blk: {
        const filepath = if (gltf_directory) |dir| try std.fs.path.join(allocator, &.{ dir, uri }) else uri;
        defer if (gltf_directory != null) allocator.free(filepath);
        const buffer = try std.fs.cwd().readFileAlloc(allocator, filepath, std.math.maxInt(usize));
        break :blk .{buffer, true};
    } else return error.EmptyImage;
    defer if (free) allocator.free(buffer);

    const img, const width, const height = try engine.fileformats.wuffs.load(allocator, buffer);
    const img_u8x3 = @as([*]const U8x3, @ptrCast(img.ptr))[0..img.len / 3];
    return .{ img_u8x3, width, height };
}

// TODO: consider just uploading all textures upfront rather than as part of this function
fn gltfMaterialToMaterial(vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, gltf: Gltf, gltf_directory: ?[]const u8, gltf_material: Gltf.Material, textures: *TextureManager) !Material.Parameters {
    // stuff that is in every material
    var material = blk: {
        var material: Material.Parameters = undefined;
        material.name = gltf_material.name orelse "<unnamed>";

        material.volume.medium = MaterialManager.Medium {
            .@"σ_a" = F32x3.new(.{
                @log(gltf_material.attenuation_color[0]),
                @log(gltf_material.attenuation_color[1]),
                @log(gltf_material.attenuation_color[2]),
            }).scale(-1 / gltf_material.attenuation_distance),
        };

        material.volume.phase.g = 0.0;

        {
            const dispersion = @max(gltf_material.dispersion, 0.2); // real materials have dispersion!
            const abbe_number = 20.0 / dispersion;

            const ior = gltf_material.ior;
            material.volume.ior = MaterialManager.CauchyIOR.fromAbbeNumberAndIOR(abbe_number, ior);
        }

        material.normal = if (gltf_material.normal_texture) |texture| normal: {
            const image = gltf.data.images[gltf.data.textures[texture.index].source.?];

            // this gives us rgb --> need to convert to rg
            // theoretically gltf spec claims these values should already be linear
            const img, const width, const height = try loadImage(allocator, image, gltf_directory);
            defer allocator.free(img);

            const rg = try encoder.uploadAllocator().alloc(U8x2, img.len);
            for (rg, img) |*dst, src| {
                dst.* = src.truncate();
            }
            const debug_name = try std.fmt.allocPrintSentinel(allocator, "{s} normal", .{ material.name }, 0);
            defer allocator.free(debug_name);
            break :normal try textures.upload(vc, U8x2, allocator, encoder, encoder.upload_allocator.getBufferSlice(rg), vk.Extent2D { .width = width, .height = height }, debug_name);
        } else normal: {
            const rg: *F32x2 = @ptrCast(try encoder.uploadAllocator().alignedAlloc(u8, std.mem.Alignment.fromByteUnits(vk_helpers.texelBlockSize(vk_helpers.typeToFormat(F32x2))), @sizeOf(F32x2)));
            rg.* = Material.Parameters.default_normal;
            break :normal try textures.upload(vc, F32x2, allocator, encoder, encoder.upload_allocator.getBufferSlice(rg), vk.Extent2D { .width = 1, .height = 1 }, "default normal");
        };

        material.emissive = if (gltf_material.emissive_texture) |texture| emissive: {
            const image = gltf.data.images[gltf.data.textures[texture.index].source.?];

            const img, const width, const height = try loadImage(allocator, image, gltf_directory);
            defer allocator.free(img);

            const rgba = try encoder.uploadAllocator().alloc(U8x4, img.len);
            for (rgba, img) |*dst, src| {
                dst.* = src.append(0);
            }

            const debug_name = try std.fmt.allocPrintSentinel(allocator, "{s} emissive", .{ material.name }, 0);
            defer allocator.free(debug_name);
            break :emissive try textures.upload(vc, U8x4, allocator, encoder, encoder.upload_allocator.getBufferSlice(rgba), vk.Extent2D { .width = width, .height = height }, debug_name);
        } else emissive: {
            const constant: *F32x4 = @ptrCast(try encoder.uploadAllocator().alignedAlloc(u8, std.mem.Alignment.fromByteUnits(vk_helpers.texelBlockSize(vk_helpers.typeToFormat(F32x4))), @sizeOf(F32x4)));
            constant.* = F32x3.new(gltf_material.emissive_factor).scale(gltf_material.emissive_strength).append(std.math.nan(f32));
            const debug_name = try std.fmt.allocPrintSentinel(allocator, "{s} constant emissive {f}", .{ material.name, constant }, 0);
            defer allocator.free(debug_name);
            break :emissive try textures.upload(vc, F32x4, allocator, encoder, encoder.upload_allocator.getBufferSlice(constant), vk.Extent2D { .width = 1, .height = 1 }, debug_name);
        };

        break :blk material;
    };

    var standard_pbr: MaterialManager.StandardPBR = undefined;

    if (gltf_material.transmission_factor == 1.0) {
        material.bsdf = .{ .glass = {} };
        return material;
    }

    {
        const dispersion = @max(gltf_material.dispersion, 0.2); // real materials have dispersion!
        const abbe_number = 20.0 / dispersion;

        standard_pbr.ior = MaterialManager.CauchyIOR.fromAbbeNumberAndIOR(abbe_number, gltf_material.ior);
    }

    standard_pbr.color = if (gltf_material.metallic_roughness.base_color_texture) |texture| blk: {
        const image = gltf.data.images[gltf.data.textures[texture.index].source.?];

        const img, const width, const height = try loadImage(allocator, image, gltf_directory);
        defer allocator.free(img);
        const rgba = try encoder.uploadAllocator().alloc(U8x4, img.len);
        for (rgba, img) |*dst, src| {
            dst.* = src.append(0);
        }

        const debug_name = try std.fmt.allocPrintSentinel(allocator, "{s} color", .{ material.name }, 0);
        defer allocator.free(debug_name);
        break :blk try textures.upload(vc, U8x4, allocator, encoder, encoder.upload_allocator.getBufferSlice(rgba), vk.Extent2D { .width = width, .height = height }, debug_name);
    } else blk: {
        const constant: *F32x4 = @ptrCast(try encoder.uploadAllocator().alignedAlloc(u8, std.mem.Alignment.fromByteUnits(vk_helpers.texelBlockSize(vk_helpers.typeToFormat(F32x4))), @sizeOf(F32x4)));
        constant.* = F32x3.new(gltf_material.metallic_roughness.base_color_factor[0..3].*).append(std.math.nan(f32));
        const debug_name = try std.fmt.allocPrintSentinel(allocator, "{s} constant color {f}", .{ material.name, constant }, 0);
        defer allocator.free(debug_name);
        break :blk try textures.upload(vc, F32x4, allocator, encoder, encoder.upload_allocator.getBufferSlice(constant), vk.Extent2D { .width = 1, .height = 1 }, debug_name);
    };

    if (gltf_material.metallic_roughness.metallic_roughness_texture) |texture| {
        const image = gltf.data.images[gltf.data.textures[texture.index].source.?];

        // this gives us rgb --> only need g (roughness) and b (metalness) channels
        // theoretically gltf spec claims these values should already be linear
        const img, const width, const height = try loadImage(allocator, image, gltf_directory);
        defer allocator.free(img);

        const metalness = try encoder.uploadAllocator().alloc(u8, img.len);
        const roughness = try encoder.uploadAllocator().alloc(u8, img.len);
        for (metalness, roughness, img) |*dst1, *dst2, src| {
            dst1.* = src.element(2);
            dst2.* = src.element(1);
        }
        const debug_name_metalness = try std.fmt.allocPrintSentinel(allocator, "{s} metalness", .{ material.name }, 0);
        defer allocator.free(debug_name_metalness);
        standard_pbr.metalness = try textures.upload(vc, u8, allocator, encoder, encoder.upload_allocator.getBufferSlice(metalness), vk.Extent2D { .width = width, .height = height }, debug_name_metalness);
        const debug_name_roughness = try std.fmt.allocPrintSentinel(allocator, "{s} roughness", .{ material.name }, 0);
        defer allocator.free(debug_name_roughness);
        standard_pbr.roughness = try textures.upload(vc, u8, allocator, encoder, encoder.upload_allocator.getBufferSlice(roughness), vk.Extent2D { .width = width, .height = height }, debug_name_roughness);
        material.bsdf = .{ .standard_pbr = standard_pbr };
        return material;
    } else {
        if (gltf_material.metallic_roughness.metallic_factor == 0.0 and gltf_material.metallic_roughness.roughness_factor == 1.0) {
            // parse as lambert
            const lambert = MaterialManager.Lambert {
                .color = standard_pbr.color,
            };
            material.bsdf = .{ .lambert = lambert };
            return material;
        } else if (gltf_material.metallic_roughness.metallic_factor == 1.0 and gltf_material.metallic_roughness.roughness_factor == 0.0) {
            // parse as perfect mirror
            material.bsdf = .{ .perfect_mirror = {} };
            return material;
        } else {
            const debug_name_metalness = try std.fmt.allocPrintSentinel(allocator, "{s} constant metalness {}", .{ material.name, gltf_material.metallic_roughness.metallic_factor }, 0);
            defer allocator.free(debug_name_metalness);
            const metalness = try encoder.uploadAllocator().create(f32);
            metalness.* = gltf_material.metallic_roughness.metallic_factor;
            standard_pbr.metalness = try textures.upload(vc, f32, allocator, encoder, encoder.upload_allocator.getBufferSlice(metalness), vk.Extent2D { .width = 1, .height = 1 }, debug_name_metalness);

            const debug_name_roughness = try std.fmt.allocPrintSentinel(allocator, "{s} constant roughness {}", .{ material.name, gltf_material.metallic_roughness.roughness_factor }, 0);
            defer allocator.free(debug_name_roughness);
            const roughness = try encoder.uploadAllocator().create(f32);
            roughness.* = gltf_material.metallic_roughness.roughness_factor;
            standard_pbr.roughness = try textures.upload(vc, f32, allocator, encoder, encoder.upload_allocator.getBufferSlice(roughness), vk.Extent2D { .width = 1, .height = 1 }, debug_name_roughness);

            material.bsdf = .{ .standard_pbr = standard_pbr };
            return material;
        }
    }
}

// glTF doesn't correspond very well to the internal data structures here so this is very inefficient
// also very inefficient because it's written very inefficiently, can remove a lot of copying, but that's a problem for another time
pub fn fromGltf(vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, gltf: Gltf, gltf_directory: ?[]const u8) !Self {
    var materials = blk: {
        var materials = try MaterialManager.createEmpty(vc);
        errdefer materials.destroy(vc, allocator);

        for (gltf.data.materials) |material| {
            const mat = try gltfMaterialToMaterial(vc, allocator, encoder, gltf, gltf_directory, material, &materials.textures);
            _ = try materials.upload(vc, allocator, encoder, mat);
        }

        const default_material = try gltfMaterialToMaterial(vc, allocator, encoder, gltf, gltf_directory, Gltf.Material {
            .name = "default",
        }, &materials.textures);
        _ = try materials.upload(vc, allocator, encoder, default_material);

        break :blk materials;
    };
    errdefer materials.destroy(vc, allocator);

    const buffers = try allocator.alloc([]align(4) const u8, gltf.data.buffers.len);
    defer allocator.free(buffers);
    for (gltf.data.buffers, buffers) |src, *dst| {
        if (src.uri) |uri| {
            const bytes = try allocator.alignedAlloc(u8, .@"4", src.byte_length);
            const filepath = if (gltf_directory) |dir| try std.fs.path.join(allocator, &.{ dir, uri }) else uri;
            defer if (gltf_directory != null) allocator.free(filepath);
            _ = try std.fs.cwd().readFile(filepath, bytes);
            dst.* = bytes;
        } else {
            dst.* = gltf.glb_binary.?;
        }
    }
    defer for (buffers[(if (gltf.glb_binary != null) 1 else 0)..]) |buffer| allocator.free(buffer);

    var meshes = MeshManager {};
    errdefer meshes.destroy(vc, allocator);

    var models = try ModelManager.createEmpty(vc, allocator, materials.textures.descriptor_layout);
    errdefer models.destroy(vc, allocator);

    // need to keep this sparse mapping as we may discard meshes that moonshine
    // does not support
    var gltf_mesh_idx_to_model = try allocator.alloc(?struct {
        handle: ModelManager.Handle,
        thin: bool
    }, gltf.data.meshes.len);
    defer allocator.free(gltf_mesh_idx_to_model);
    @memset(gltf_mesh_idx_to_model, null);

    for (gltf.data.meshes, 0..) |mesh, mesh_idx| {
        var geometries = std.array_list.Managed(Geometry.Parameters).init(allocator);
        defer geometries.deinit();
        try geometries.ensureTotalCapacityPrecise(mesh.primitives.len);
        var model_thin: bool = undefined;
        for (mesh.primitives, 0..) |primitive, primitive_idx| {
            std.debug.assert(primitive.mode == .triangles);

            const material, const thin = if (primitive.material) |material_idx| blk: {
                const material = gltf.data.materials[material_idx];
                // ignore primitives that have a non-opaque alpha mode. there's no support for texture opacity,
                // and ignoring them is a better approximation than making them exist but be opaque
                if (material.alpha_mode != .@"opaque") continue;
                const thin = material.thickness_factor == 0;
                break :blk .{ material_idx, thin };
            } else .{ (materials.material_count - 1), true };
            if (primitive_idx != 0) {
                // thickness in moonshine is on a per-instance basis, but gltf is per-material.
                // currently, just assert all materials in an instance have same thickness.
                // a better solution would be to break-up instances with non-same thickness.
                std.debug.assert(model_thin == thin);
            }
            model_thin = thin;

            const indices = if (primitive.indices) |indices_index| indices: {
                const accessor = gltf.data.accessors[indices_index];
                const buffer = buffers[gltf.data.buffer_views[accessor.buffer_view.?].buffer];

                break :indices switch (accessor.component_type) {
                    .unsigned_byte => blk: {
                        const indices = try gltf.getDataFromBufferView(u8, allocator, accessor, buffer);
                        defer allocator.free(indices);

                        // convert to U32x3
                        const indices_u32 = try encoder.uploadAllocator().alloc(U32x3, indices.len / 3);
                        for (indices_u32, 0..) |*index, i| {
                            index.* = U8x3.fromArray(indices[i * 3..][0..3].*).intCast(u32);
                        }
                        break :blk indices_u32;
                    },
                    .unsigned_short => blk: {
                        const indices = try gltf.getDataFromBufferView(u16, allocator, accessor, buffer);
                        defer allocator.free(indices);

                        // convert to U32x3
                        const indices_u32 = try encoder.uploadAllocator().alloc(U32x3, indices.len / 3);
                        for (indices_u32, 0..) |*index, i| {
                            index.* = U16x3.fromArray(indices[i * 3..][0..3].*).intCast(u32);
                        }
                        break :blk indices_u32;
                    },
                    .unsigned_integer => blk: {
                        const indices = try gltf.getDataFromBufferView(u32, encoder.uploadAllocator(), accessor, buffer);
                        break :blk @as([]const U32x3, @ptrCast(indices));
                    },
                    else => unreachable,
                };
            } else null;
            errdefer if (indices) |nonnull| encoder.uploadAllocator().free(nonnull);

            var positions: []const F32x3 = &.{};
            errdefer encoder.uploadAllocator().free(positions);
            var texcoords: []const F32x2 = &.{};
            errdefer encoder.uploadAllocator().free(texcoords);
            var normals: []const F32x3 = &.{};
            errdefer encoder.uploadAllocator().free(normals);

            for (primitive.attributes) |attribute| {
                switch (attribute) {
                    .position => |accessor_index| {
                        const accessor = gltf.data.accessors[accessor_index];
                        const buffer = buffers[gltf.data.buffer_views[accessor.buffer_view.?].buffer];
                        const slice = try gltf.getDataFromBufferView(f32, encoder.uploadAllocator(), accessor, buffer);
                        positions = @ptrCast(slice);
                    },
                    .texcoord => |accessor_index| {
                        // mesh may have many texcoords that we can use, but moonshine only knows how to use one set of them currently
                        // so ignore any after the first
                        if (texcoords.len != 0) continue;
                        const accessor = gltf.data.accessors[accessor_index];
                        const buffer = buffers[gltf.data.buffer_views[accessor.buffer_view.?].buffer];
                        const slice = try gltf.getDataFromBufferView(f32, encoder.uploadAllocator(), accessor, buffer);
                        texcoords = @ptrCast(slice);
                    },
                    .normal => |accessor_index| {
                        const accessor = gltf.data.accessors[accessor_index];
                        const buffer = buffers[gltf.data.buffer_views[accessor.buffer_view.?].buffer];
                        const slice = try gltf.getDataFromBufferView(f32, encoder.uploadAllocator(), accessor, buffer);
                        normals = @ptrCast(slice);
                    },
                    else => {},
                }
            }
            std.debug.assert(positions.len > 0);

            const mesh_handle = try meshes.upload(vc, allocator, encoder, MeshManager.Mesh.Parameters {
                .name = mesh.name orelse "<unnamed>",
                .positions = encoder.upload_allocator.getBufferSlice(positions),
                .texcoords = if (texcoords.len != 0) encoder.upload_allocator.getBufferSlice(texcoords) else null,
                .normals = if (normals.len != 0) encoder.upload_allocator.getBufferSlice(normals) else null,
                .indices = if (indices) |i| encoder.upload_allocator.getBufferSlice(i) else null,
            });

            geometries.appendAssumeCapacity(Geometry.Parameters {
                .mesh = mesh_handle,
                .material = @intCast(material),
            });
        }

        if (geometries.items.len == 0) continue;

        gltf_mesh_idx_to_model[mesh_idx] = .{
            .handle = try models.upload(vc, allocator, encoder, meshes, materials, geometries.items),
            .thin = model_thin,
        };
    }

    var accel = try Accel.createEmpty(vc, allocator);
    errdefer accel.destroy(vc);

    // TODO: iterate over nodes in hierarchy order rather than flat so
    // that looking up transforms is not O(n^2)
    for (gltf.data.nodes) |node| {
        if (node.mesh) |mesh_idx| {
            if (gltf_mesh_idx_to_model[mesh_idx]) |model| {
                const mat_array = Gltf.getGlobalTransform(&gltf.data, node);
                const transform = Mat4.fromCols(.{ .new(mat_array[0]), .new(mat_array[1]), .new(mat_array[2]), .new(mat_array[3]) });
                _ = try accel.uploadInstance(vc, encoder, models, Instance {
                    .transform = transform.truncateRow(),
                    .model = model.handle,
                    .thin = model.thin,
                });
            }
        }
    }

    return Self {
        .materials = materials,
        .meshes = meshes,
        .models = models,
        .accel = accel,
        .constant_spectra = try ConstantSpectra.create(vc, encoder),
    };
}

pub fn createEmpty(vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder) !Self {
    var materials = try MaterialManager.createEmpty(vc);
    errdefer materials.destroy(vc, allocator);

    return Self {
        .materials = materials,
        .meshes = .{},
        .models = try ModelManager.createEmpty(vc, allocator, materials.textures.descriptor_layout),
        .accel = try Accel.createEmpty(vc, allocator),
        .constant_spectra = try ConstantSpectra.create(vc, encoder),
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.materials.destroy(vc, allocator);
    self.meshes.destroy(vc, allocator);
    self.models.destroy(vc, allocator);
    self.accel.destroy(vc);
    self.constant_spectra.destroy(vc);
}
