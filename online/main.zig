const std = @import("std");

const engine = @import("engine");
const Camera = engine.rendersystem.Camera;
const World = engine.rendersystem.World;
const Background = engine.rendersystem.Background;
const VulkanContext = engine.rendersystem.VulkanContext;
const VkAllocator = engine.rendersystem.Allocator;
const Pipeline = engine.rendersystem.pipeline.StandardPipeline;
const descriptor = engine.rendersystem.descriptor;
const WorldDescriptorLayout = descriptor.WorldDescriptorLayout;
const BackgroundDescriptorLayout = descriptor.BackgroundDescriptorLayout;
const FilmDescriptorLayout = descriptor.FilmDescriptorLayout;
const Commands = engine.rendersystem.Commands;
const utils = engine.rendersystem.utils;
const displaysystem = engine.displaysystem;

const Display = displaysystem.Display(2);

const Window = @import("./Window.zig");
const Gui = @import("./Gui.zig");
const imgui = @import("./imgui.zig");

const vector = engine.vector;
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);
const Mat4 = vector.Mat4(f32);
const Mat3x4 = vector.Mat3x4(f32);
const Vec3 = vector.Vec3(f32);

const vk = @import("vulkan");

const Config = struct {
    in_filepath: []const u8, // must be glb
    skybox_filepath: []const u8, // must be exr
    extent: vk.Extent2D,

    fn fromCli(allocator: std.mem.Allocator) !Config {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);
        if (args.len != 3) return error.BadArgs;

        const in_filepath = args[1];
        if (!std.mem.eql(u8, std.fs.path.extension(in_filepath), ".glb")) return error.OnlySupportsGlbInput;

        const skybox_filepath = args[2];
        if (!std.mem.eql(u8, std.fs.path.extension(skybox_filepath), ".exr")) return error.OnlySupportsExrSkybox;

        return Config {
            .in_filepath = try allocator.dupe(u8, in_filepath),
            .skybox_filepath = try allocator.dupe(u8, skybox_filepath),
            .extent = vk.Extent2D { .width = 1280, .height = 720 }, // TODO: cli
        };
    }

    fn destroy(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.in_filepath);
        allocator.free(self.skybox_filepath);
    }
};

fn queueFamilyAcceptable(instance: vk.Instance, device: vk.PhysicalDevice, idx: u32) bool {
    return Window.getPhysicalDevicePresentationSupport(instance, device, idx);
}

pub const vulkan_context_instance_functions = displaysystem.required_instance_functions;
pub const vulkan_context_device_functions = displaysystem.required_device_functions.merge(Gui.required_device_functions);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try Config.fromCli(allocator);
    defer config.destroy(allocator);

    const window = try Window.create(config.extent.width, config.extent.height, "online");
    defer window.destroy();

    const context = try VulkanContext.create(allocator, "online", &window.getRequiredInstanceExtensions(), &.{ vk.extension_info.khr_swapchain.name }, queueFamilyAcceptable);
    defer context.destroy();
    
    var vk_allocator = try VkAllocator.create(&context, allocator);
    defer vk_allocator.destroy(&context, allocator);

    const window_extent = window.getExtent();
    var display = try Display.create(&context, window_extent, try window.createSurface(context.instance.handle));
    defer display.destroy(&context, allocator);

    var commands = try Commands.create(&context);
    defer commands.destroy(&context);

    var gui = try Gui.create(&context, display.swapchain, window, window_extent, &vk_allocator, allocator, &commands);
    defer gui.destroy(&context, allocator);

    var world_descriptor_layout = try WorldDescriptorLayout.create(&context, 1, .{});
    defer world_descriptor_layout.destroy(&context);
    var background_descriptor_layout = try BackgroundDescriptorLayout.create(&context, 1, .{});
    defer background_descriptor_layout.destroy(&context);
    var film_descriptor_layout = try FilmDescriptorLayout.create(&context, 1, .{});
    defer film_descriptor_layout.destroy(&context);

    std.log.info("Set up initial state!", .{});

    var pipeline = try Pipeline.create(&context, &vk_allocator, allocator, &commands, .{ world_descriptor_layout, background_descriptor_layout, film_descriptor_layout }, .{ .{} });
    defer pipeline.destroy(&context);

    std.log.info("Created pipeline!", .{});

    var camera_create_info = try Camera.CreateInfo.fromGlb(allocator, config.in_filepath);
    var camera = try Camera.create(&context, &vk_allocator, allocator, &film_descriptor_layout, config.extent, camera_create_info);
    defer camera.destroy(&context, allocator);
    try commands.transitionImageLayout(&context, allocator, camera.film.images.data.items(.handle)[1..], .@"undefined", .general);

    var world = try World.fromGlb(&context, &vk_allocator, allocator, &commands, &world_descriptor_layout, config.in_filepath);
    defer world.destroy(&context, allocator);

    std.log.info("Loaded world!", .{});

    var background = try Background.create(&context, &vk_allocator, allocator, &commands, &background_descriptor_layout, world.sampler, config.skybox_filepath);
    defer background.destroy(&context, allocator);

    std.log.info("Created background!", .{});

    var window_data = WindowData {
        .camera = &camera,
        .camera_info = &camera_create_info,
    };

    window.setAspectRatio(config.extent.width, config.extent.height);
    window.setUserPointer(&window_data);
    window.setKeyCallback(keyCallback);

    while (!window.shouldClose()) {
        const command_buffer = if (display.startFrame(&context)) |buffer| buffer else |err| switch (err) {
            error.OutOfDateKHR => blk: {
                try display.recreate(&context, allocator, window.getExtent());
                try gui.resize(&context, display.swapchain);
                break :blk try display.startFrame(&context); // don't recreate on second failure
            },
            else => return err,
        };
        // transition swap image to one we can blit to from display
        // and accumulation image to one we can write to in shader
        const output_image_barriers = [_]vk.ImageMemoryBarrier2 {
            .{
                .dst_stage_mask = .{ .blit_bit = true, },
                .dst_access_mask = .{ .transfer_write_bit = true, },
                .old_layout = .@"undefined",
                .new_layout = .transfer_dst_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = display.swapchain.currentImage(),
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            },
            .{
                .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true, },
                .dst_access_mask = .{ .shader_storage_write_bit = true, },
                .old_layout = .@"undefined",
                .new_layout = .general,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = camera.film.images.data.items(.handle)[0],
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            },
        };
        context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
            .image_memory_barrier_count = output_image_barriers.len,
            .p_image_memory_barriers = &output_image_barriers,
        });

        pipeline.recordBindDescriptorSets(&context, command_buffer, [_]vk.DescriptorSet { world.descriptor_set, background.descriptor_set, camera.film.descriptor_set });

        // bind some stuff
        pipeline.recordBindPipeline(&context, command_buffer);
        
        // push some stuff
        const bytes = std.mem.asBytes(&.{camera.properties, camera.film.sample_count });
        context.device.cmdPushConstants(command_buffer, pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

        // trace some stuff
        pipeline.recordTraceRays(&context, command_buffer, camera.film.extent);

        // transition storage image to one we can blit from
        const image_memory_barriers = [_]vk.ImageMemoryBarrier2 {
            .{
                .src_stage_mask = .{ .ray_tracing_shader_bit_khr = true, },
                .src_access_mask = .{ .shader_storage_write_bit = true, },
                .dst_stage_mask = .{ .blit_bit = true, },
                .dst_access_mask = .{ .transfer_read_bit = true, },
                .old_layout = .general,
                .new_layout = .transfer_src_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = camera.film.images.data.items(.handle)[0],
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }
        };
        context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
            .image_memory_barrier_count = image_memory_barriers.len,
            .p_image_memory_barriers = &image_memory_barriers,
        });

        // blit storage image onto swap image
        const subresource = vk.ImageSubresourceLayers {
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        };

        const region = vk.ImageBlit {
            .src_subresource = subresource,
            .src_offsets = .{
                .{
                    .x = 0,
                    .y = 0,
                    .z = 0,
                }, .{
                    .x = @intCast(i32, camera.film.extent.width),
                    .y = @intCast(i32, camera.film.extent.height),
                    .z = 1,
                }
            },
            .dst_subresource = subresource,
            .dst_offsets = .{
                .{
                    .x = 0,
                    .y = 0,
                    .z = 0,
                }, .{
                    .x = @intCast(i32, display.swapchain.extent.width),
                    .y = @intCast(i32, display.swapchain.extent.height),
                    .z = 1,
                },
            },
        };

        context.device.cmdBlitImage(command_buffer, camera.film.images.data.items(.handle)[0], .transfer_src_optimal, display.swapchain.currentImage(), .transfer_dst_optimal, 1, utils.toPointerType(&region), .nearest);
        context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &[_]vk.ImageMemoryBarrier2 {
                .{
                    .src_stage_mask = .{ .blit_bit = true, },
                    .src_access_mask = .{ .transfer_write_bit = true, },
                    .dst_stage_mask = .{ .color_attachment_output_bit = true, },
                    .dst_access_mask = .{ .color_attachment_write_bit = true, },
                    .old_layout = .transfer_dst_optimal,
                    .new_layout = .color_attachment_optimal,
                    .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                    .image = display.swapchain.currentImage(),
                    .subresource_range = .{
                        .aspect_mask = .{ .color_bit = true },
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                }
            },
        });
    
        gui.startFrame();
        imgui.setNextWindowPos(50, 50);
        imgui.setNextWindowSize(250, 150);
        imgui.begin("Camera");
        try imgui.textFmt("Sample count: {}", .{ camera.film.sample_count });
        try imgui.textFmt("Focus distance: {d:.2}", .{ camera_create_info.focus_distance });
        try imgui.textFmt("Aperture size: {d:.2}", .{ camera_create_info.aperture });
        try imgui.textFmt("Origin: {d:.2}", .{ camera_create_info.origin });
        try imgui.textFmt("Forward: {d:.2}", .{ camera_create_info.forward });
        try imgui.textFmt("Up: {d:.2}", .{ camera_create_info.forward });
        imgui.end();
        imgui.setNextWindowPos(50, 250);
        imgui.setNextWindowSize(250, 100);
        imgui.begin("Metrics");
        try imgui.textFmt("Last frame time: {d:.3}ms", .{ display.last_frame_time_ns / std.time.ns_per_ms });
        try imgui.textFmt("Framerate: {d:.2} FPS", .{ imgui.getIO().Framerate });
        imgui.end();
        gui.endFrame(&context, command_buffer, display.swapchain.image_index, display.frame_index);

        // transition swapchain back to present mode
        const return_swap_image_memory_barriers = [_]vk.ImageMemoryBarrier2 {
            .{
                .src_stage_mask = .{ .color_attachment_output_bit = true, },
                .src_access_mask = .{ .color_attachment_write_bit = true, },
                .old_layout = .color_attachment_optimal,
                .new_layout = .present_src_khr,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = display.swapchain.currentImage(),
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }
        };
        context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
            .image_memory_barrier_count = return_swap_image_memory_barriers.len,
            .p_image_memory_barriers = &return_swap_image_memory_barriers,
        });

        if (display.endFrame(&context)) |ok| {
            // only update frame count if we presented successfully
            camera.film.sample_count += 1;
            if (ok == vk.Result.suboptimal_khr) {
                try display.recreate(&context, allocator, window.getExtent());
                try gui.resize(&context, display.swapchain);
            }
        } else |err| {
            if (err == error.OutOfDateKHR) {
                try display.recreate(&context, allocator, window.getExtent());
                try gui.resize(&context, display.swapchain);
            }
        }

        window.pollEvents();
    }
    try context.device.deviceWaitIdle();

    std.log.info("Program completed!", .{});
}

const WindowData = struct {
    camera: *Camera,
    camera_info: *Camera.CreateInfo,
};

fn keyCallback(window: *const Window, key: u32, action: Window.Action, mods: Window.ModifierKeys) void {

    const ptr = window.getUserPointer().?;
    const window_data = @ptrCast(*WindowData, @alignCast(@alignOf(WindowData), ptr));

    if (action == .repeat or action == .press) {
        var camera_info = window_data.camera_info;
        const side = camera_info.forward.cross(camera_info.up).unit();

        switch (key) {
            'W' => if (mods.shift) {
                camera_info.forward = Mat4.fromAxisAngle(side, 0.01).mul_vec(camera_info.forward).unit();
            } else {
                camera_info.origin = camera_info.origin.add(camera_info.forward.mul_scalar(0.1));
            },
            'S' => if (mods.shift) {
                camera_info.forward = Mat4.fromAxisAngle(side, -0.01).mul_vec(camera_info.forward).unit();
            } else {
                camera_info.origin = camera_info.origin.sub(camera_info.forward.mul_scalar(0.1));
            },
            'D' => if (mods.shift) {
                camera_info.forward = Mat4.fromAxisAngle(camera_info.up, -0.01).mul_vec(camera_info.forward).unit();
            } else {
                camera_info.origin = camera_info.origin.add(side.mul_scalar(0.1));
            },
            'A' => if (mods.shift) {
                camera_info.forward = Mat4.fromAxisAngle(camera_info.up, 0.01).mul_vec(camera_info.forward).unit();
            } else {
                camera_info.origin = camera_info.origin.sub(side.mul_scalar(0.1));
            },
            'F' => if (camera_info.aperture > 0.0) { camera_info.aperture -= 0.005; },
            'R' => camera_info.aperture += 0.005,
            'Q' => camera_info.focus_distance -= 0.01,
            'E' => camera_info.focus_distance += 0.01,
            else => return,
        }

        window_data.camera_info = camera_info;
        window_data.camera.properties = Camera.Properties.new(camera_info.*);
        window_data.camera.film.clear();
    }
}
