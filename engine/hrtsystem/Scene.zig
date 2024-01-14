const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");

const engine = @import("../engine.zig");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const VkAllocator = core.Allocator;
const Commands = core.Commands;

const Background = @import("./BackgroundManager.zig");
const World = @import("./World.zig");
const Camera = @import("./Camera.zig");

const MsneReader = engine.fileformats.msne.MsneReader;
const exr = engine.fileformats.exr;

const Self = @This();

world: World,
background: Background,
camera: Camera,

// glTF doesn't correspond very well to the internal data structures here so this is very inefficient
// also very inefficient because it's written very inefficiently, can remove a lot of copying, but that's a problem for another time
// inspection bool specifies whether some buffers should be created with the `transfer_src_flag` for inspection
pub fn fromGlbExr(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, glb_filepath: []const u8, skybox_filepath: []const u8, extent: vk.Extent2D, inspection: bool) !Self {
    var gltf = Gltf.init(allocator);
    defer gltf.deinit();

    const buffer = try std.fs.cwd().readFileAlloc(
        allocator,
        glb_filepath,
        std.math.maxInt(usize),
    );
    defer allocator.free(buffer);
    try gltf.parse(buffer);

    const camera_create_info = try Camera.CreateInfo.fromGlb(gltf);
    var camera = try Camera.create(vc, vk_allocator, extent, camera_create_info);
    errdefer camera.destroy(vc);

    var world = try World.fromGlb(vc, vk_allocator, allocator, commands, gltf, inspection);
    errdefer world.destroy(vc, allocator);

    var background = try Background.create(vc);
    errdefer background.destroy(vc, allocator);
    {
        const skybox_image = try exr.helpers.Rgba2D.load(allocator, skybox_filepath);
        defer allocator.free(skybox_image.asSlice());
        try background.addBackground(vc, vk_allocator, allocator, commands, skybox_image, "exr");
    }

    return Self {
        .world = world,
        .background = background,
        .camera = camera,
    };
}

pub fn fromMsneExr(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, msne_filepath: []const u8, skybox_filepath: []const u8, extent: vk.Extent2D, inspection: bool) !Self {
    const msne = try MsneReader.fromFilepath(msne_filepath);
    defer msne.destroy();

    var world = try World.fromMsne(vc, vk_allocator, allocator, commands, msne, inspection);
    errdefer world.destroy(vc, allocator);

    const camera_create_info = try Camera.CreateInfo.fromMsne(msne);
    var camera = try Camera.create(vc, vk_allocator, extent, camera_create_info);
    errdefer camera.destroy(vc);

    var background = try Background.create(vc);
    errdefer background.destroy(vc, allocator);
    {
        const skybox_image = try exr.helpers.Rgba2D.load(allocator, skybox_filepath);
        defer allocator.free(skybox_image.asSlice());
        try background.addBackground(vc, vk_allocator, allocator, commands, skybox_image, "exr");
    }

    return Self {
        .world = world,
        .background = background,
        .camera = camera,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.world.destroy(vc, allocator);
    self.background.destroy(vc, allocator);
    self.camera.destroy(vc);
}
