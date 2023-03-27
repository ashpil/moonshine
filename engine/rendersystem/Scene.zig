const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");

const core = @import("../engine.zig").core;
const VulkanContext = core.VulkanContext;

const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const descriptor = @import("./descriptor.zig");
const WorldDescriptorLayout = descriptor.WorldDescriptorLayout;
const BackgroundDescriptorLayout = descriptor.BackgroundDescriptorLayout;
const FilmDescriptorLayout = descriptor.FilmDescriptorLayout;

const Background = @import("./Background.zig");
const World = @import("./World.zig");
const Camera = @import("./Camera.zig");

const Self = @This();

world_descriptor_layout: WorldDescriptorLayout,
background_descriptor_layout: BackgroundDescriptorLayout,
film_descriptor_layout: FilmDescriptorLayout,

world: World,
background: Background,
camera: Camera,

camera_create_info: Camera.CreateInfo,

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

    var world_descriptor_layout = try WorldDescriptorLayout.create(vc, 1, .{});
    errdefer world_descriptor_layout.destroy(vc);
    var background_descriptor_layout = try BackgroundDescriptorLayout.create(vc, 1, .{});
    errdefer background_descriptor_layout.destroy(vc);
    var film_descriptor_layout = try FilmDescriptorLayout.create(vc, 1, .{});
    errdefer film_descriptor_layout.destroy(vc);

    var camera_create_info = try Camera.CreateInfo.fromGlb(gltf);
    var camera = try Camera.create(vc, vk_allocator, allocator, &film_descriptor_layout, extent, camera_create_info);
    errdefer camera.destroy(vc, allocator);
    try commands.transitionImageLayout(vc, allocator, camera.film.images.data.items(.handle)[1..], .undefined, .general);

    var world = try World.fromGlb(vc, vk_allocator, allocator, commands, &world_descriptor_layout, gltf, inspection);
    errdefer world.destroy(vc, allocator);

    var background = try Background.create(vc, vk_allocator, allocator, commands, &background_descriptor_layout, world.sampler, skybox_filepath);
    errdefer background.destroy(vc, allocator);

    return Self{
        .world_descriptor_layout = world_descriptor_layout,
        .background_descriptor_layout = background_descriptor_layout,
        .film_descriptor_layout = film_descriptor_layout,

        .world = world,
        .background = background,
        .camera = camera,

        .camera_create_info = camera_create_info,
    };
}

pub fn fromMsneExr(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, msne_filepath: []const u8, skybox_filepath: []const u8, extent: vk.Extent2D, inspection: bool) !Self {
    var world_descriptor_layout = try WorldDescriptorLayout.create(vc, 1, .{});
    errdefer world_descriptor_layout.destroy(vc);
    var background_descriptor_layout = try BackgroundDescriptorLayout.create(vc, 1, .{});
    errdefer background_descriptor_layout.destroy(vc);
    var film_descriptor_layout = try FilmDescriptorLayout.create(vc, 1, .{});
    errdefer film_descriptor_layout.destroy(vc);

    const file = try std.fs.cwd().openFile(msne_filepath, .{});
    defer file.close();

    const reader = file.reader();
    std.debug.assert(std.mem.eql(u8, &try reader.readBytesNoEof(4), "MSNE"));

    var world = try World.fromMsne(vc, vk_allocator, allocator, commands, &world_descriptor_layout, reader, inspection);
    errdefer world.destroy(vc, allocator);

    var camera_create_info = try Camera.CreateInfo.fromMsne(reader);
    var camera = try Camera.create(vc, vk_allocator, allocator, &film_descriptor_layout, extent, camera_create_info);
    errdefer camera.destroy(vc, allocator);
    try commands.transitionImageLayout(vc, allocator, camera.film.images.data.items(.handle)[1..], .undefined, .general);

    var background = try Background.create(vc, vk_allocator, allocator, commands, &background_descriptor_layout, world.sampler, skybox_filepath);
    errdefer background.destroy(vc, allocator);

    return Self{
        .world_descriptor_layout = world_descriptor_layout,
        .background_descriptor_layout = background_descriptor_layout,
        .film_descriptor_layout = film_descriptor_layout,

        .world = world,
        .background = background,
        .camera = camera,

        .camera_create_info = camera_create_info,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.world_descriptor_layout.destroy(vc);
    self.background_descriptor_layout.destroy(vc);
    self.film_descriptor_layout.destroy(vc);

    self.world.destroy(vc, allocator);
    self.background.destroy(vc, allocator);
    self.camera.destroy(vc, allocator);
}
