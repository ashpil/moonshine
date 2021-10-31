const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("../renderer/VulkanContext.zig");
const MeshData = @import("../utils/Object.zig");
const Images = @import("../renderer/Images.zig");

const TransferCommands = @import("../renderer/commands.zig").ComputeCommands;

const Meshes = @import("../renderer/Meshes.zig");
const Accel = @import("../renderer/Accel.zig");
const utils = @import("../renderer/utils.zig");

const Mat3x4 = @import("../utils/zug.zig").Mat3x4(f32);

pub const Material = struct {
    color: Images.TextureSource,
    roughness: Images.TextureSource,
    normal: Images.TextureSource,

    metallic: f32,
    ior: f32,
};

pub const GpuMaterial = packed struct {
    metallic: f32,
    ior: f32,
};

pub const Instances = Accel.Instances;
pub const InstanceMeshInfo = Accel.MeshInfo;

background: Images,

color_textures: Images,
roughness_textures: Images,
normal_textures: Images,

meshes: Meshes,
accel: Accel,

materials_buffer: vk.Buffer,
materials_memory: vk.DeviceMemory,

instance_info: []InstanceMeshInfo,

const Self = @This();

pub fn create(vc: *const VulkanContext, commands: *TransferCommands, comptime materials: []const Material, comptime background_filepath: []const u8, comptime mesh_filepaths: []const []const u8, instances: Instances, allocator: *std.mem.Allocator) !Self {
    const background = try Images.createTexture(vc, allocator, &[_]Images.TextureSource {
        Images.TextureSource {
            .filepath = background_filepath,
        }
    }, commands);

    comptime var color_sources: [materials.len]Images.TextureSource = undefined;
    comptime var roughness_sources: [materials.len]Images.TextureSource = undefined;
    comptime var normal_sources: [materials.len]Images.TextureSource = undefined;

    comptime var gpu_materials: [materials.len]GpuMaterial = undefined;

    comptime for (materials) |set, i| {
        color_sources[i] = set.color;
        roughness_sources[i] = set.roughness;
        normal_sources[i] = set.normal;

        gpu_materials[i].ior = set.ior;
        gpu_materials[i].metallic = set.metallic;
    };

    const color_textures = try Images.createTexture(vc, allocator, &color_sources, commands);
    const roughness_textures = try Images.createTexture(vc, allocator, &roughness_sources, commands);
    const normal_textures = try Images.createTexture(vc, allocator, &normal_sources, commands);

    var materials_buffer: vk.Buffer = undefined;
    var materials_memory: vk.DeviceMemory = undefined;
    try utils.createBuffer(vc, @sizeOf(GpuMaterial) * materials.len, .{ .storage_buffer_bit = true, .transfer_dst_bit = true }, .{ .device_local_bit = true }, &materials_buffer, &materials_memory);
    errdefer vc.device.freeMemory(materials_memory, null);
    errdefer vc.device.destroyBuffer(materials_buffer, null);

    try commands.uploadData(vc, materials_buffer, std.mem.asBytes(&gpu_materials));

    var objects: [mesh_filepaths.len]MeshData = undefined;
    
    inline for (mesh_filepaths) |mesh_filepath, i| {
        objects[i] = try MeshData.fromObj(allocator, @embedFile(mesh_filepath));
    }

    defer for (objects) |*object| {
        object.destroy(allocator);
    };

    // set it all to undefined to it can be filled below
    var geometry_infos = Accel.GeometryInfos {};
    defer geometry_infos.deinit(allocator);
    try geometry_infos.ensureTotalCapacity(allocator, mesh_filepaths.len);
    geometry_infos.len = mesh_filepaths.len;

    const geometry_infos_slice = geometry_infos.slice();
    const geometries = geometry_infos_slice.items(.geometry);
    var build_infos: [mesh_filepaths.len]vk.AccelerationStructureBuildRangeInfoKHR = undefined;
    
    var meshes = try Meshes.create(vc, commands, allocator, &objects, geometries, &build_infos);
    errdefer meshes.destroy(vc, allocator);

    var build_infos_ref = geometry_infos_slice.items(.build_info);
    comptime var i = 0;
    inline while (i < mesh_filepaths.len) : (i += 1) {
        build_infos_ref[i] = &build_infos[i];
    }

    var accel = try Accel.create(vc, allocator, commands, geometry_infos, instances);
    errdefer accel.destroy(vc, allocator);

    const instance_info = @ptrCast([*]InstanceMeshInfo, (try allocator.realloc(instances.bytes[0..instances.capacity * @sizeOf(Instances.Elem)], @sizeOf(InstanceMeshInfo) * instances.len)).ptr)[0..instances.len];

    return Self {
        .background = background,

        .color_textures = color_textures,
        .roughness_textures = roughness_textures,
        .normal_textures = normal_textures,

        .materials_buffer = materials_buffer,
        .materials_memory = materials_memory,

        .meshes = meshes,
        .accel = accel,

        .instance_info = instance_info,
    };
}

pub fn update(self: *Self, index: u32, new_transform: Mat3x4) !void {
    self.instance_info[index].transform = new_transform;
    try self.accel.updateTlas(self.instance_info);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator) void {
    allocator.free(self.instance_info);

    self.background.destroy(vc, allocator);
    self.color_textures.destroy(vc, allocator);
    self.roughness_textures.destroy(vc, allocator);
    self.normal_textures.destroy(vc, allocator);
    self.meshes.destroy(vc, allocator);
    self.accel.destroy(vc, allocator);

    vc.device.destroyBuffer(self.materials_buffer, null);
    vc.device.freeMemory(self.materials_memory, null);
}
