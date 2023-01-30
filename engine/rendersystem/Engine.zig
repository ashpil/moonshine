const std = @import("std");
const vk = @import("vulkan");
const shaders = @import("shaders");

const VulkanContext = @import("./VulkanContext.zig");
const Window = @import("../Window.zig");
const Pipeline = @import("./pipeline.zig").StandardPipeline;
const descriptor = @import("./descriptor.zig");
const WorldDescriptorLayout = descriptor.WorldDescriptorLayout;
const BackgroundDescriptorLayout = descriptor.BackgroundDescriptorLayout;
const FilmDescriptorLayout = descriptor.FilmDescriptorLayout;
const Display = @import("./display.zig").Display(frames_in_flight);
const Camera = @import("./Camera.zig");
const Film = @import("./Film.zig");

const F32x3 = @import("../vector.zig").Vec3(f32);

const Commands = @import("./Commands.zig");
const VkAllocator = @import("./Allocator.zig");
const World = @import("./World.zig");
const Background = @import("./Background.zig");

const utils = @import("./utils.zig");

const frames_in_flight = 2;

const Self = @This();

context: VulkanContext,
display: Display,
film: Film,
commands: Commands,
world_descriptor_layout: WorldDescriptorLayout,
background_descriptor_layout: BackgroundDescriptorLayout,
film_descriptor_layout: FilmDescriptorLayout,
camera_create_info: Camera.CreateInfo,
camera: Camera,
pipeline: Pipeline,
allocator: VkAllocator,

pub fn create(allocator: std.mem.Allocator, window: *const Window, app_name: [*:0]const u8) !Self {

    const initial_window_size = window.getExtent();

    const context = try VulkanContext.create(.{ .allocator = allocator, .window = window, .app_name = app_name });
    var vk_allocator = try VkAllocator.create(&context, allocator);

    const world_descriptor_layout = try WorldDescriptorLayout.create(&context, 1, .{});
    const background_descriptor_layout = try BackgroundDescriptorLayout.create(&context, 1, .{});
    const film_descriptor_layout = try FilmDescriptorLayout.create(&context, 1, .{});

    var commands = try Commands.create(&context);
    const display = try Display.create(&context, initial_window_size);
    const film = try Film.create(&context, &vk_allocator, allocator, &film_descriptor_layout, initial_window_size);
    try commands.transitionImageLayout(&context, allocator, film.images.data.items(.handle)[1..], .@"undefined", .general);

    const camera_origin = F32x3.new(0.6, 0.5, -0.6);
    const camera_target = F32x3.new(0.0, 0.0, 0.0);
    const camera_create_info = .{
        .origin = camera_origin,
        .target = camera_target,
        .up = F32x3.new(0.0, 1.0, 0.0),
        .vfov = 0.6,
        .aspect = @intToFloat(f32, initial_window_size.width) / @intToFloat(f32, initial_window_size.height),
        .aperture = 0.007,
        .focus_distance = camera_origin.sub(camera_target).length(),
    };
    const camera = Camera.new(camera_create_info);

    const pipeline = try Pipeline.create(&context, &vk_allocator, allocator, &commands, .{ world_descriptor_layout, background_descriptor_layout, film_descriptor_layout }, .{ .{} });

    return Self {
        .context = context,
        .film = film,
        .display = display,
        .commands = commands,
        .world_descriptor_layout = world_descriptor_layout,
        .background_descriptor_layout = background_descriptor_layout,
        .film_descriptor_layout = film_descriptor_layout,
        .camera_create_info = camera_create_info,
        .camera = camera,
        .pipeline = pipeline,

        .allocator = vk_allocator,
    };
}

pub fn setScene(self: *Self, world: *const World, background: *const Background, buffer: vk.CommandBuffer) void {
    const sets = [_]vk.DescriptorSet { world.descriptor_set, background.descriptor_set, self.film.descriptor_set };
    self.context.device.cmdBindDescriptorSets(buffer, .ray_tracing_khr, self.pipeline.layout, 0, sets.len, &sets, 0, undefined);
}

pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
    self.allocator.destroy(&self.context, allocator);
    self.world_descriptor_layout.destroy(&self.context);
    self.background_descriptor_layout.destroy(&self.context);
    self.film_descriptor_layout.destroy(&self.context);
    self.pipeline.destroy(&self.context);
    self.commands.destroy(&self.context);
    self.film.destroy(&self.context, allocator);
    self.display.destroy(&self.context, allocator);
    self.context.destroy();
}

pub fn startFrame(self: *Self, window: *const Window, allocator: std.mem.Allocator) !vk.CommandBuffer {
    const command_buffer = try self.display.startFrame(&self.context, allocator, window);

    // transition swap image to one we can blit to from display
    // and accumulation image to one we can write to in shader
    const output_image_barriers = [_]vk.ImageMemoryBarrier2 {
        .{
            .src_stage_mask = .{},
            .src_access_mask = .{},
            .dst_stage_mask = .{ .blit_bit = true, },
            .dst_access_mask = .{ .transfer_write_bit = true, },
            .old_layout = .@"undefined",
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.display.swapchain.currentImage(),
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
        .{
            .src_stage_mask = .{},
            .src_access_mask = .{},
            .dst_stage_mask = .{ .ray_tracing_shader_bit_khr = true, },
            .dst_access_mask = .{ .shader_storage_write_bit = true, },
            .old_layout = .@"undefined",
            .new_layout = .general,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.film.images.data.items(.handle)[0],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        },
    };
    self.context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = undefined,
        .buffer_memory_barrier_count = 0,
        .p_buffer_memory_barriers = undefined,
        .image_memory_barrier_count = output_image_barriers.len,
        .p_image_memory_barriers = &output_image_barriers,
    });

    return command_buffer;
}

pub fn recordFrame(self: *Self, command_buffer: vk.CommandBuffer) !void {
    // bind some stuff
    self.context.device.cmdBindPipeline(command_buffer, .ray_tracing_khr, self.pipeline.handle);
    
    // push some stuff
    const bytes = std.mem.asBytes(&.{self.camera.desc, self.camera.blur_desc, self.film.sample_count });
    self.context.device.cmdPushConstants(command_buffer, self.pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

    // trace some stuff
    self.pipeline.recordTraceRays(&self.context, command_buffer, self.film.extent);
}

pub fn endFrame(self: *Self, window: *const Window, allocator: std.mem.Allocator, command_buffer: vk.CommandBuffer) !void {
    // transition storage image to one we can blit from
    const image_memory_barriers = [_]vk.ImageMemoryBarrier2 {
        .{
            .src_stage_mask = .{ .ray_tracing_shader_bit_khr = true, },
            .src_access_mask = .{ .shader_storage_write_bit = true, },
            .dst_stage_mask = .{ .blit_bit = true, },
            .dst_access_mask = .{ .transfer_write_bit = true, },
            .old_layout = .general,
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.film.images.data.items(.handle)[0],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }
    };
    self.context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = undefined,
        .buffer_memory_barrier_count = 0,
        .p_buffer_memory_barriers = undefined,
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
                .x = @intCast(i32, self.film.extent.width),
                .y = @intCast(i32, self.film.extent.height),
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
                .x = @intCast(i32, self.display.swapchain.extent.width),
                .y = @intCast(i32, self.display.swapchain.extent.height),
                .z = 1,
            },
        },
    };

    self.context.device.cmdBlitImage(command_buffer, self.film.images.data.items(.handle)[0], .transfer_src_optimal, self.display.swapchain.currentImage(), .transfer_dst_optimal, 1, utils.toPointerType(&region), .nearest);

    // transition swapchain back to present mode
    const return_swap_image_memory_barriers = [_]vk.ImageMemoryBarrier2 {
        .{
            .src_stage_mask = .{ .blit_bit = true, },
            .src_access_mask = .{ .transfer_write_bit = true, },
            .dst_stage_mask = .{},
            .dst_access_mask = .{},
            .old_layout = .transfer_dst_optimal,
            .new_layout = .present_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.display.swapchain.currentImage(),
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }
    };
    self.context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        .dependency_flags = .{},
        .memory_barrier_count = 0,
        .p_memory_barriers = undefined,
        .buffer_memory_barrier_count = 0,
        .p_buffer_memory_barriers = undefined,
        .image_memory_barrier_count = return_swap_image_memory_barriers.len,
        .p_image_memory_barriers = &return_swap_image_memory_barriers,
    });

    // only update frame count if we presented successfully
    // if we got OutOfDateKHR error, just ignore and continue, next frame should be better
    if (self.display.endFrame(&self.context, allocator, window)) {
        self.film.sample_count += 1;
    } else |err| if (err != error.OutOfDateKHR) {
        return err;
    }
}
