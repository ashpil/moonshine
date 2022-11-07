// a scene contains:
// - a list of meshes
// - an acceleration structure/mesh heirarchy
// - materials
// - a background

const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const MeshData = @import("../Object.zig");
const ImageManager = @import("./ImageManager.zig");

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
    color: ImageManager.TextureSource,
    roughness: ImageManager.TextureSource,
    normal: ImageManager.TextureSource,

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

// actually probably should go into some MaterialManager, which has one ImageManager
textures: ImageManager, // (color, roughness, normal) * N
materials_buffer: VkAllocator.DeviceBuffer, // holds GpuMaterial info about materials

mesh_manager: MeshManager,
accel: Accel,

instance_info: []InstanceMeshInfo, // used to update heirarchy transforms

sampler: vk.Sampler,
descriptor_set: vk.DescriptorSet,

const Self = @This();

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, comptime materials: []const Material, comptime background_dir: []const u8, mesh_filepaths: []const []const u8, instances: Instances, descriptor_layout: *const SceneDescriptorLayout, background_descriptor_layout: *const BackgroundDescriptorLayout) !Self {
    comptime var texture_sources: [materials.len * 3]ImageManager.TextureSource = undefined;

    const gpu_materials = try vk_allocator.createHostBuffer(vc, GpuMaterial, @intCast(u32, materials.len), .{ .transfer_src_bit = true });
    defer gpu_materials.destroy(vc);

    comptime for (materials) |set, i| {
        texture_sources[3 * i + 0] = set.color;
        texture_sources[3 * i + 1] = set.roughness;
        texture_sources[3 * i + 2] = set.normal;

        gpu_materials.data[i].ior = set.ior;
        gpu_materials.data[i].metalness = set.metalness;
    };

    const materials_buffer = try vk_allocator.createDeviceBuffer(vc, allocator, @sizeOf(GpuMaterial) * materials.len, .{ .storage_buffer_bit = true, .transfer_dst_bit = true });
    errdefer materials_buffer.destroy(vc);

    try commands.startRecording(vc);
    commands.recordUploadBuffer(GpuMaterial, vc, materials_buffer, gpu_materials);
    try commands.submitAndIdleUntilDone(vc);

    var textures = try ImageManager.createTexture(vc, vk_allocator, allocator, &texture_sources, commands);
    errdefer textures.destroy(vc, allocator);

    var image_infos: [materials.len * 3]vk.DescriptorImageInfo = undefined;

    const texture_views = textures.data.items(.view);
    inline for (image_infos) |*info, i| {
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
            .descriptor_count = image_infos.len,
            .descriptor_type = .sampled_image,
            .p_image_info = &image_infos,
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

        .textures = textures,
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
    self.textures.destroy(vc, allocator);
    self.mesh_manager.destroy(vc, allocator);
    self.accel.destroy(vc, allocator);

    self.materials_buffer.destroy(vc);
}
