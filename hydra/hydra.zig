const std = @import("std");
const vk = @import("vulkan");

const engine = @import("engine");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Commands = core.Commands;
const VkAllocator = core.Allocator;

const hrtsystem = engine.hrtsystem;
const Scene = hrtsystem.Scene;
const Camera = hrtsystem.Camera;
const Pipeline = hrtsystem.pipeline.StandardPipeline;

pub const vulkan_context_device_functions = hrtsystem.required_device_functions;

const Allocator = std.heap.GeneralPurposeAllocator(.{});

comptime {
    _ = HdMoonshine;
}

pub const HdMoonshine = struct {
    allocator: Allocator,
    vk_allocator: VkAllocator,
    vc: VulkanContext,
    commands: Commands,
    scene: Scene,
    pipeline: Pipeline,
    output_buffer: VkAllocator.HostBuffer([4]f32),

    pub export fn HdMoonshineCreate() ?*HdMoonshine {
        var allocator = Allocator {};
        errdefer _ = allocator.deinit();

        const self = allocator.allocator().create(HdMoonshine) catch return null;
        errdefer allocator.allocator().destroy(self);

        self.allocator = allocator;
        self.vc = VulkanContext.create(self.allocator.allocator(), "hdMoonshine", &.{}, &hrtsystem.required_device_extensions, &hrtsystem.required_device_features, null) catch return null;
        errdefer self.vc.destroy();

        self.commands = Commands.create(&self.vc) catch return null;
        errdefer self.commands.destroy(&self.vc);

        self.vk_allocator = VkAllocator.create(&self.vc, self.allocator.allocator()) catch return null;
        errdefer self.vk_allocator.destroy(&self.vc, self.allocator.allocator());

        self.scene = Scene.createEmpty(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, Camera.CreateInfo {}, vk.Extent2D { .width = 601, .height = 495 }) catch return null;
        errdefer self.scene.destroy(&self.vc, self.allocator.allocator());

        self.pipeline = Pipeline.create(&self.vc, &self.vk_allocator, self.allocator.allocator(), &self.commands, .{ self.scene.world_descriptor_layout, self.scene.background.descriptor_layout, self.scene.film_descriptor_layout }, .{
            .@"0" = .{
                .samples_per_run = 1,
                .max_bounces = 1024,
                .env_samples_per_bounce = 1,
                .mesh_samples_per_bounce = 1,
            }
        }) catch return null;
        errdefer self.pipeline.destroy(&self.vc);

        self.output_buffer = self.vk_allocator.createHostBuffer(&self.vc, [4]f32, self.scene.camera.film.extent.width * self.scene.camera.film.extent.height, .{ .transfer_dst_bit = true }) catch return null;
        errdefer self.output_buffer.destroy(&self.vc);

        return self;
    }

    pub export fn HdMoonshineRender(self: *HdMoonshine, out: [*]f32) bool {
        self.commands.startRecording(&self.vc) catch return false;

        // prepare our stuff
        self.scene.camera.film.recordPrepareForCapture(&self.vc, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true });

        // bind our stuff
        self.pipeline.recordBindPipeline(&self.vc, self.commands.buffer);
        self.pipeline.recordBindDescriptorSets(&self.vc, self.commands.buffer, [_]vk.DescriptorSet { self.scene.world.descriptor_set, self.scene.background.data.items[0].descriptor_set, self.scene.camera.film.descriptor_set });
        
        // push our stuff
        const bytes = std.mem.asBytes(&.{ self.scene.camera.properties, @as(u32, 0) });
        self.vc.device.cmdPushConstants(self.commands.buffer, self.pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

        // trace our stuff
        self.pipeline.recordTraceRays(&self.vc, self.commands.buffer, self.scene.camera.film.extent);

        // copy our stuff
        self.scene.camera.film.recordPrepareForCopy(&self.vc, self.commands.buffer, .{ .ray_tracing_shader_bit_khr = true }, .{ .copy_bit = true });

        // copy rendered image to host-visible staging buffer
        const copy = vk.BufferImageCopy {
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{
                .x = 0,
                .y = 0,
                .z = 0,
            },
            .image_extent = .{
                .width = self.scene.camera.film.extent.width,
                .height = self.scene.camera.film.extent.height,
                .depth = 1,
            },  
        };
        self.vc.device.cmdCopyImageToBuffer(self.commands.buffer, self.scene.camera.film.images.data.items(.handle)[0], .transfer_src_optimal, self.output_buffer.handle, 1, @ptrCast(&copy));
 
        self.commands.submitAndIdleUntilDone(&self.vc) catch return false;

        @memcpy(@as([*][4]f32, @ptrCast(out)), self.output_buffer.data);

        return true;
    }

    pub export fn HdMoonshineDestroy(self: *HdMoonshine) void {
        self.output_buffer.destroy(&self.vc);
        self.pipeline.destroy(&self.vc);
        self.scene.destroy(&self.vc, self.allocator.allocator());
        self.commands.destroy(&self.vc);
        self.vk_allocator.destroy(&self.vc, self.allocator.allocator());
        self.vc.destroy();
        var alloc = self.allocator;
        alloc.allocator().destroy(self);
        _ = alloc.deinit();
    }
};

