// a scene contains:
// - a list of meshes
// - an acceleration structure/mesh heirarchy
// - materials
// - a background

const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const MeshData = @import("../Object.zig");
const Images = @import("./Images.zig");

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

const Mat3x4 = @import("../vector.zig").Mat3x4(f32);

pub const Material = struct {
    color: Images.TextureSource,
    roughness: Images.TextureSource,
    normal: Images.TextureSource,

    metalness: f32,
    ior: f32,
};

pub const GpuMaterial = packed struct {
    metalness: f32,
    ior: f32,
};

pub const Instances = Accel.Instances;
pub const InstanceMeshInfo = Accel.MeshInfo;

background: Background,

// TODO: should be some sort of one texture array with indices or something?
// handle to ImageManager or something instead
// actually probably should go into some MaterialManager, which has one ImageManager
color_textures: Images,
roughness_textures: Images,
normal_textures: Images,

materials_buffer: VkAllocator.DeviceBuffer, // holds GpuMaterial info about materials

mesh_manager: MeshManager,
accel: Accel,

instance_info: []InstanceMeshInfo, // used to update heirarchy transforms

sampler: vk.Sampler,
descriptor_set: vk.DescriptorSet,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, comptime materials: []const Material, comptime background_dir: []const u8, mesh_filepaths: []const []const u8, instances: Instances, descriptor_layout: *const SceneDescriptorLayout, background_descriptor_layout: *const BackgroundDescriptorLayout) !Self {
    comptime var color_sources: [materials.len]Images.TextureSource = undefined;
    comptime var roughness_sources: [materials.len]Images.TextureSource = undefined;
    comptime var normal_sources: [materials.len]Images.TextureSource = undefined;

    const gpu_materials = try vk_allocator.createHostBuffer(vc, GpuMaterial, @intCast(u32, materials.len), .{ .transfer_src_bit = true });
    defer gpu_materials.destroy(vc);

    var color_image_info: [materials.len]vk.DescriptorImageInfo = undefined;
    var roughness_image_info: [materials.len]vk.DescriptorImageInfo = undefined;
    var normal_image_info: [materials.len]vk.DescriptorImageInfo = undefined;

    comptime for (materials) |set, i| {
        color_sources[i] = set.color;
        roughness_sources[i] = set.roughness;
        normal_sources[i] = set.normal;

        gpu_materials.data[i].ior = set.ior;
        gpu_materials.data[i].metalness = set.metalness;
    };

    const materials_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(GpuMaterial) * materials.len, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
    errdefer materials_buffer.destroy(vc);

    try commands.startRecording(vc);
    commands.recordUploadBuffer(GpuMaterial, vc, materials_buffer, gpu_materials);
    try commands.submitAndIdleUntilDone(vc);

    var color_textures = try Images.createTexture(vc, vk_allocator, allocator, &color_sources, commands);
    var roughness_textures = try Images.createTexture(vc, vk_allocator, allocator, &roughness_sources, commands);
    var normal_textures = try Images.createTexture(vc, vk_allocator, allocator, &normal_sources, commands);

    errdefer color_textures.destroy(vc, allocator);
    errdefer roughness_textures.destroy(vc, allocator);
    errdefer normal_textures.destroy(vc, allocator);

    const color_views = color_textures.data.items(.view);
    const roughness_views = roughness_textures.data.items(.view);
    const normal_views = normal_textures.data.items(.view);

    inline for (materials) |_, i| {
        color_image_info[i] = .{
            .sampler = .null_handle,
            .image_view = color_views[i],
            .image_layout = .shader_read_only_optimal,
        };
        roughness_image_info[i] = .{
            .sampler = .null_handle,
            .image_view = roughness_views[i],
            .image_layout = .shader_read_only_optimal,
        };
        normal_image_info[i] = .{
            .sampler = .null_handle,
            .image_view = normal_views[i],
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

    const sampler = try Images.createSampler(vc);

    const background = try Background.create(vc, vk_allocator, allocator, commands, background_dir, background_descriptor_layout, sampler);

    const descriptor_set = (try descriptor_layout.allocate_sets(vc, 1, [8]vk.WriteDescriptorSet {
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
                .buffer = materials_buffer.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 3,
            .dst_array_element = 0,
            .descriptor_count = color_image_info.len,
            .descriptor_type = .sampled_image,
            .p_image_info = &color_image_info,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 4,
            .dst_array_element = 0,
            .descriptor_count = roughness_image_info.len,
            .descriptor_type = .sampled_image,
            .p_image_info = &roughness_image_info,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 5,
            .dst_array_element = 0,
            .descriptor_count = normal_image_info.len,
            .descriptor_type = .sampled_image,
            .p_image_info = &normal_image_info,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 6,
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
            .dst_binding = 7,
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

        .color_textures = color_textures,
        .roughness_textures = roughness_textures,
        .normal_textures = normal_textures,

        .materials_buffer = materials_buffer,

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
    self.color_textures.destroy(vc, allocator);
    self.roughness_textures.destroy(vc, allocator);
    self.normal_textures.destroy(vc, allocator);
    self.mesh_manager.destroy(vc, allocator);
    self.accel.destroy(vc, allocator);

    self.materials_buffer.destroy(vc);
}
