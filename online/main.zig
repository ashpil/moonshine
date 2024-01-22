const std = @import("std");

const engine = @import("engine");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Commands = core.Commands;
const VkAllocator = core.Allocator;
const DestructionQueue = core.DestructionQueue;
const vk_helpers = core.vk_helpers;
const SyncCopier = core.SyncCopier;
const TextureManager = core.Images.TextureManager;
const StorageImageManager = core.Images.StorageImageManager;

const hrtsystem = engine.hrtsystem;
const Camera = hrtsystem.Camera;
const Accel = hrtsystem.Accel;
const MaterialManager = hrtsystem.MaterialManager;
const Scene = hrtsystem.Scene;
const Pipeline = hrtsystem.pipeline.StandardPipeline;
const ObjectPicker = hrtsystem.ObjectPicker;

const displaysystem = engine.displaysystem;
const Display = displaysystem.Display;
const Window = engine.Window;
const Platform = engine.gui.Platform;
const imgui = engine.gui.imgui;

const vector = engine.vector;
const F32x4 = vector.Vec4(f32);
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);
const Mat4 = vector.Mat4(f32);
const Mat3x4 = vector.Mat3x4(f32);

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

        return Config{
            .in_filepath = try allocator.dupe(u8, in_filepath),
            .skybox_filepath = try allocator.dupe(u8, skybox_filepath),
            .extent = vk.Extent2D{ .width = 1280, .height = 720 }, // TODO: cli
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
pub const vulkan_context_device_functions = displaysystem.required_device_functions.merge(Platform.required_device_functions).merge(hrtsystem.required_device_functions);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try Config.fromCli(allocator);
    defer config.destroy(allocator);

    const window = try Window.create(config.extent.width, config.extent.height, "online");
    defer window.destroy();

    const context = try VulkanContext.create(allocator, "online", &window.getRequiredInstanceExtensions(), &(displaysystem.required_device_extensions ++ hrtsystem.required_device_extensions), &hrtsystem.required_device_features, queueFamilyAcceptable);
    defer context.destroy();

    var vk_allocator = try VkAllocator.create(&context, allocator);
    defer vk_allocator.destroy(&context, allocator);

    const window_extent = window.getExtent();
    var display = try Display.create(&context, window_extent, try window.createSurface(context.instance.handle));
    defer display.destroy(&context);

    var commands = try Commands.create(&context);
    defer commands.destroy(&context);

    var gui = try Platform.create(&context, display.swapchain, window, window_extent, &vk_allocator, allocator, &commands);
    defer gui.destroy(&context, allocator);

    var destruction_queue = DestructionQueue.create(); // TODO: need to clean this every once in a while since we're only allowed a limited amount of most types of handles
    defer destruction_queue.destroy(&context, allocator);

    var sync_copier = try SyncCopier.create(&context, &vk_allocator, @sizeOf(vk.AccelerationStructureInstanceKHR));
    defer sync_copier.destroy(&context);

    var images = StorageImageManager {};
    defer images.destroy(&context, allocator);

    var textures = try TextureManager.create(&context);
    defer textures.destroy(&context, allocator);

    std.log.info("Set up initial state!", .{});

    var scene = try Scene.fromGlbExr(&context, &vk_allocator, allocator, &images, &textures, &commands, config.in_filepath, config.skybox_filepath, config.extent, true);

    defer scene.destroy(&context, allocator);

    std.log.info("Loaded scene!", .{});

    var object_picker = try ObjectPicker.create(&context, &vk_allocator, allocator, scene.world.descriptor_layout, scene.camera.descriptor_layout, &commands);
    defer object_picker.destroy(&context);

    var pipeline_constants = Pipeline.SpecConstants{};
    var pipeline_opts = &pipeline_constants.@"0";
    var pipeline = try Pipeline.create(&context, &vk_allocator, allocator, &commands, .{ textures.descriptor_layout, scene.world.descriptor_layout, scene.background.descriptor_layout, scene.camera.descriptor_layout }, pipeline_constants);
    defer pipeline.destroy(&context);

    std.log.info("Created pipelines!", .{});

    var window_data = WindowData{
        .camera = &scene.camera,
    };

    // window.setAspectRatio(config.extent.width, config.extent.height);
    window.setUserPointer(&window_data);
    window.setKeyCallback(keyCallback);

    // random state we need for gui
    var max_sample_count: u32 = 0; // unlimited
    var rebuild_label_buffer: [20]u8 = undefined;
    var rebuild_label = try std.fmt.bufPrintZ(&rebuild_label_buffer, "Rebuild", .{});
    var rebuild_error = false;
    var has_clicked = false;
    var current_clicked_object: ?ObjectPicker.ClickedObject = null;
    var current_clicked_color = F32x3.new(0.0, 0.0, 0.0);

    while (!window.shouldClose()) {
        const command_buffer = if (display.startFrame(&context)) |buffer| buffer else |err| switch (err) {
            error.OutOfDateKHR => blk: {
                try display.recreate(&context, window.getExtent(), &destruction_queue, allocator);
                try gui.resize(&context, display.swapchain);
                break :blk try display.startFrame(&context); // don't recreate on second failure
            },
            else => return err,
        };

        gui.startFrame();
        imgui.setNextWindowPos(50, 50);
        imgui.setNextWindowSize(250, 350);
        imgui.begin("Settings");
        if (imgui.collapsingHeader("Metrics")) {
            try imgui.textFmt("Last frame time: {d:.3}ms", .{display.last_frame_time_ns / std.time.ns_per_ms});
            try imgui.textFmt("Framerate: {d:.2} FPS", .{imgui.getIO().Framerate});
        }
        if (imgui.collapsingHeader("Sensor")) {
            if (imgui.button("Reset", imgui.Vec2{ .x = imgui.getContentRegionAvail().x - imgui.getFontSize() * 10, .y = 0 })) {
                scene.camera.sensors.items[0].clear();
            }
            imgui.sameLine();
            try imgui.textFmt("Sample count: {}", .{scene.camera.sensors.items[0].sample_count});
            imgui.pushItemWidth(imgui.getFontSize() * -10);
            _ = imgui.inputScalar(u32, "Max sample count", &max_sample_count, 1, 100);
            imgui.popItemWidth();
        }
        if (imgui.collapsingHeader("Camera")) {
            imgui.pushItemWidth(imgui.getFontSize() * -7.5);
            var changed = imgui.sliderAngle("Vertical FOV", &scene.camera.lenses.items[0].vfov, 1, 179);
            changed = imgui.dragScalar(f32, "Focus distance", &scene.camera.lenses.items[0].focus_distance, 0.1, -std.math.inf(f32), std.math.inf(f32)) or changed;
            changed = imgui.dragScalar(f32, "Aperture size", &scene.camera.lenses.items[0].aperture, 0.01, 0.0, std.math.inf(f32)) or changed;
            changed = imgui.dragVector(F32x3, "Origin", &scene.camera.lenses.items[0].origin, 0.1, -std.math.inf(f32), std.math.inf(f32)) or changed;
            changed = imgui.dragVector(F32x3, "Forward", &scene.camera.lenses.items[0].forward, 0.1, -1.0, 1.0) or changed;
            changed = imgui.dragVector(F32x3, "Up", &scene.camera.lenses.items[0].up, 0.1, -1.0, 1.0) or changed;
            if (changed) {
                scene.camera.lenses.items[0].forward = scene.camera.lenses.items[0].forward.unit();
                scene.camera.lenses.items[0].up = scene.camera.lenses.items[0].up.unit();
                scene.camera.sensors.items[0].clear();
            }
            imgui.popItemWidth();
        }
        if (imgui.collapsingHeader("Pipeline")) {
            imgui.pushItemWidth(imgui.getFontSize() * -14.2);
            _ = imgui.dragScalar(u32, "Samples per frame", &pipeline_opts.samples_per_run, 1.0, 1, std.math.maxInt(u32));
            imgui.popStyleColor();
            _ = imgui.dragScalar(u32, "Max light bounces", &pipeline_opts.max_bounces, 1.0, 0, std.math.maxInt(u32));
            _ = imgui.dragScalar(u32, "Env map samples per bounce", &pipeline_opts.env_samples_per_bounce, 1.0, 0, std.math.maxInt(u32));
            _ = imgui.dragScalar(u32, "Mesh samples per bounce", &pipeline_opts.mesh_samples_per_bounce, 1.0, 0, std.math.maxInt(u32));
            const last_rebuild_failed = rebuild_error;
            if (last_rebuild_failed) imgui.pushStyleColor(.text, F32x4.new(1.0, 0.0, 0.0, 1));
            if (imgui.button(rebuild_label, imgui.Vec2{ .x = imgui.getContentRegionAvail().x, .y = 0.0 })) {
                const start = try std.time.Instant.now();
                if (pipeline.recreate(&context, &vk_allocator, allocator, &commands, pipeline_constants, &destruction_queue)) {
                    const elapsed = (try std.time.Instant.now()).since(start) / std.time.ns_per_ms;
                    rebuild_label = try std.fmt.bufPrintZ(&rebuild_label_buffer, "Rebuild ({d}ms)", .{elapsed});
                    rebuild_error = false;
                    scene.camera.sensors.items[0].clear();
                } else |err| if (err == error.ShaderCompileFail) {
                    rebuild_error = true;
                    rebuild_label = try std.fmt.bufPrintZ(&rebuild_label_buffer, "Rebuild (error)", .{});
                } else return err;
            }
            if (last_rebuild_failed) imgui.popStyleColor();
            imgui.popItemWidth();
        }
        imgui.end();
        imgui.setNextWindowPos(@as(f32, @floatFromInt(display.swapchain.extent.width - 50)) - 250, 50);
        imgui.setNextWindowSize(250, 350);
        imgui.begin("Click");
        if (has_clicked) {
            imgui.separatorText("pixel");
            _ = imgui.colorEdit("Pixel color", &current_clicked_color, .{ .no_inputs = true, .no_options = true, .no_picker = true });
            imgui.pushItemWidth(imgui.getFontSize() * -12);
            if (current_clicked_object) |object| {
                imgui.separatorText("data");
                try imgui.textFmt("Instance index: {d}", .{object.instance_index});
                try imgui.textFmt("Geometry index: {d}", .{object.geometry_index});
                // TODO: all of the copying below should be done once, on object pick
                const instance = try sync_copier.copyBufferItem(&context, vk.AccelerationStructureInstanceKHR, scene.world.accel.instances_device, object.instance_index);
                const accel_geometry_index = instance.instance_custom_index_and_mask.instance_custom_index + object.geometry_index;
                var geometry = try sync_copier.copyBufferItem(&context, Accel.Geometry, scene.world.accel.geometries, accel_geometry_index);
                const material = try sync_copier.copyBufferItem(&context, MaterialManager.Material, scene.world.material_manager.materials, geometry.material);
                try imgui.textFmt("Mesh index: {d}", .{geometry.mesh});
                if (imgui.inputScalar(u32, "Material index", &geometry.material, null, null) and geometry.material < scene.world.material_manager.material_count) {
                    scene.world.accel.recordUpdateSingleMaterial(&context, command_buffer, accel_geometry_index, geometry.material);
                    scene.camera.sensors.items[0].clear();
                }
                try imgui.textFmt("Sampled: {}", .{geometry.sampled});
                imgui.separatorText("mesh");
                const mesh = scene.world.mesh_manager.meshes.get(geometry.mesh);
                try imgui.textFmt("Vertex count: {d}", .{mesh.vertex_count});
                try imgui.textFmt("Index count: {d}", .{mesh.index_count});
                try imgui.textFmt("Has texcoords: {}", .{!mesh.texcoord_buffer.is_null()});
                try imgui.textFmt("Has normals: {}", .{!mesh.normal_buffer.is_null()});
                imgui.separatorText("material");
                try imgui.textFmt("normal: {}", .{material.normal});
                try imgui.textFmt("emissive: {}", .{material.emissive});
                try imgui.textFmt("type: {s}", .{@tagName(material.type)});
                inline for (@typeInfo(MaterialManager.MaterialType).Enum.fields, @typeInfo(MaterialManager.MaterialVariant).Union.fields) |enum_field, union_field| {
                    const VariantType = union_field.type;
                    if (VariantType != void and enum_field.value == @intFromEnum(material.type)) {
                        const material_idx: u32 = @intCast((material.addr - @field(scene.world.material_manager.variant_buffers, enum_field.name).addr) / @sizeOf(VariantType));
                        var material_variant = try sync_copier.copyBufferItem(&context, VariantType, @field(scene.world.material_manager.variant_buffers, enum_field.name).buffer, material_idx);
                        inline for (@typeInfo(VariantType).Struct.fields) |struct_field| {
                            switch (struct_field.type) {
                                f32 => if (imgui.dragScalar(f32, (struct_field.name[0..struct_field.name.len].* ++ .{ 0 })[0..struct_field.name.len :0], &@field(material_variant, struct_field.name), 0.01, 0, std.math.inf(f32))) {
                                    scene.world.material_manager.recordUpdateSingleVariant(&context, VariantType, command_buffer, material_idx, material_variant);
                                    scene.camera.sensors.items[0].clear();
                                },
                                u32 => try imgui.textFmt("{s}: {}", .{ struct_field.name, @field(material_variant, struct_field.name) }),
                                else => unreachable,
                            }
                        }
                    }
                }
                imgui.separatorText("transform");
                const old_transform: Mat3x4 = @bitCast(instance.transform);
                var translation = old_transform.extract_translation();
                imgui.pushItemWidth(imgui.getFontSize() * -6);
                if (imgui.dragVector(F32x3, "Translation", &translation, 0.1, -std.math.inf(f32), std.math.inf(f32))) {
                    scene.world.accel.recordUpdateSingleTransform(&context, command_buffer, object.instance_index, old_transform.with_translation(translation));
                    try scene.world.accel.recordRebuild(&context, command_buffer);
                    scene.camera.sensors.items[0].clear();
                }
            }
            imgui.popItemWidth();
        } else {
            imgui.text("Go click something!");
        }
        imgui.end();
        if (imgui.isMouseClicked(.left) and !imgui.getIO().WantCaptureMouse) {
            const pos = window.getCursorPos();
            const x = @as(f32, @floatCast(pos.x)) / @as(f32, @floatFromInt(display.swapchain.extent.width));
            const y = @as(f32, @floatCast(pos.y)) / @as(f32, @floatFromInt(display.swapchain.extent.height));
            current_clicked_object = try object_picker.getClickedObject(&context, F32x2.new(x, y), scene.camera, scene.world.descriptor_set, scene.camera.sensors.items[0].descriptor_set);
            const clicked_pixel = try sync_copier.copyImagePixel(&context, F32x4, images.data.get(scene.camera.sensors.items[0].image).handle, .transfer_src_optimal, vk.Offset3D { .x = @intFromFloat(pos.x), .y = @intFromFloat(pos.y), .z = 0 });
            current_clicked_color = clicked_pixel.truncate();
            has_clicked = true;
        }

        if (max_sample_count != 0 and scene.camera.sensors.items[0].sample_count > max_sample_count) scene.camera.sensors.items[0].clear();
        if (max_sample_count == 0 or scene.camera.sensors.items[0].sample_count < max_sample_count) {
            // prepare some stuff
            scene.camera.sensors.items[0].recordPrepareForCapture(&context, &images, command_buffer, .{ .ray_tracing_shader_bit_khr = true });

            // bind some stuff
            pipeline.recordBindPipeline(&context, command_buffer);
            pipeline.recordBindDescriptorSets(&context, command_buffer, [_]vk.DescriptorSet{ textures.descriptor_set, scene.world.descriptor_set, scene.background.data.items[0].descriptor_set, scene.camera.sensors.items[0].descriptor_set });

            // push some stuff
            const bytes = std.mem.asBytes(&.{ scene.camera.lenses.items[0], scene.camera.sensors.items[0].sample_count, scene.background.data.items[0].texture });
            context.device.cmdPushConstants(command_buffer, pipeline.layout, .{ .raygen_bit_khr = true }, 0, bytes.len, bytes);

            // trace some stuff
            pipeline.recordTraceRays(&context, command_buffer, scene.camera.sensors.items[0].extent);

            // copy some stuff
            scene.camera.sensors.items[0].recordPrepareForCopy(&context, &images, command_buffer, .{ .ray_tracing_shader_bit_khr = true }, .{ .blit_bit = true });
        }

        // transition swap image to one we can blit to
        context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&vk.ImageMemoryBarrier2{
                .dst_stage_mask = .{ .blit_bit = true },
                .dst_access_mask = .{ .transfer_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .image = display.swapchain.currentImage(),
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            }),
        });

        // blit storage image onto swap image
        const subresource = vk.ImageSubresourceLayers{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        };

        const region = vk.ImageBlit{
            .src_subresource = subresource,
            .src_offsets = .{ .{
                .x = 0,
                .y = 0,
                .z = 0,
            }, .{
                .x = @as(i32, @intCast(scene.camera.sensors.items[0].extent.width)),
                .y = @as(i32, @intCast(scene.camera.sensors.items[0].extent.height)),
                .z = 1,
            } },
            .dst_subresource = subresource,
            .dst_offsets = .{
                .{
                    .x = 0,
                    .y = 0,
                    .z = 0,
                },
                .{
                    .x = @as(i32, @intCast(display.swapchain.extent.width)),
                    .y = @as(i32, @intCast(display.swapchain.extent.height)),
                    .z = 1,
                },
            },
        };

        context.device.cmdBlitImage(command_buffer, images.data.get(scene.camera.sensors.items[0].image).handle, .transfer_src_optimal, display.swapchain.currentImage(), .transfer_dst_optimal, 1, @ptrCast(&region), .nearest);
        context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = &[_]vk.ImageMemoryBarrier2{.{
                .src_stage_mask = .{ .blit_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_access_mask = .{ .color_attachment_write_bit = true },
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
                    .layer_count = vk.REMAINING_ARRAY_LAYERS,
                },
            }},
        });

        gui.endFrame(&context, command_buffer, display.swapchain.image_index, display.frame_index);

        // transition swapchain back to present mode
        const return_swap_image_memory_barriers = [_]vk.ImageMemoryBarrier2{.{
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{ .color_attachment_write_bit = true },
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
                .layer_count = vk.REMAINING_ARRAY_LAYERS,
            },
        }};
        context.device.cmdPipelineBarrier2(command_buffer, &vk.DependencyInfo{
            .image_memory_barrier_count = return_swap_image_memory_barriers.len,
            .p_image_memory_barriers = &return_swap_image_memory_barriers,
        });

        if (display.endFrame(&context)) |ok| {
            // only update frame count if we presented successfully
            scene.camera.sensors.items[0].sample_count += pipeline_opts.samples_per_run;
            if (max_sample_count != 0) scene.camera.sensors.items[0].sample_count = @min(scene.camera.sensors.items[0].sample_count, max_sample_count);
            if (ok == vk.Result.suboptimal_khr) {
                try display.recreate(&context, window.getExtent(), &destruction_queue, allocator);
                try gui.resize(&context, display.swapchain);
            }
        } else |err| {
            if (err == error.OutOfDateKHR) {
                try display.recreate(&context, window.getExtent(), &destruction_queue, allocator);
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
};

fn keyCallback(window: *const Window, key: u32, action: Window.Action, mods: Window.ModifierKeys) void {
    const ptr = window.getUserPointer().?;
    const window_data: *WindowData = @ptrCast(@alignCast(ptr));

    if (action == .repeat or action == .press) {
        var camera_info = window_data.camera.lenses.items[0];
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
            'F' => if (camera_info.aperture > 0.0) {
                camera_info.aperture -= 0.005;
            },
            'R' => camera_info.aperture += 0.005,
            'Q' => camera_info.focus_distance -= 0.01,
            'E' => camera_info.focus_distance += 0.01,
            else => return,
        }

        window_data.camera.lenses.items[0] = camera_info;
        window_data.camera.sensors.items[0].clear();
    }
}
