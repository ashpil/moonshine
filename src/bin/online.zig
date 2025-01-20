const std = @import("std");

const engine = @import("engine");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const DestructionQueue = core.DestructionQueue;
const vk_helpers = core.vk_helpers;
const SyncCopier = core.SyncCopier;
const TextureManager = core.Images.TextureManager;

const hrtsystem = engine.hrtsystem;
const Camera = hrtsystem.CameraManager;
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
const Mat3 = vector.Mat3(f32);
const Mat3x4 = vector.Mat3x4(f32);

const vk = @import("vulkan");

const Config = struct {
    in_filepath: []const u8, // must be gltf/glb
    skybox_filepath: []const u8, // must be exr
    extent: vk.Extent2D,

    fn fromCli(allocator: std.mem.Allocator) !Config {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);
        if (args.len != 3) return error.BadArgs;

        const in_filepath = args[1];
        if (!std.mem.eql(u8, std.fs.path.extension(in_filepath), ".glb") and !std.mem.eql(u8, std.fs.path.extension(in_filepath), ".gltf")) return error.OnlySupportsGltfInput;

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

pub const required_vulkan_functions = displaysystem.required_vulkan_functions ++ Platform.required_vulkan_functions ++ hrtsystem.required_vulkan_functions;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try Config.fromCli(allocator);
    defer config.destroy(allocator);

    const window = try Window.create(config.extent.width, config.extent.height, "online");
    defer window.destroy();

    const context = try VulkanContext.create(allocator, "online", &window.getRequiredInstanceExtensions(), &(displaysystem.required_device_extensions ++ hrtsystem.required_device_extensions), &hrtsystem.required_device_features, queueFamilyAcceptable);
    defer context.destroy(allocator);

    const window_extent = window.getExtent();
    var display = try Display.create(&context, window_extent, try window.createSurface(context.instance.handle));
    defer display.destroy(&context);

    var encoder = try Encoder.create(&context, "main");
    defer encoder.destroy(&context);

    var sync_copier = try SyncCopier.create(&context, @sizeOf(vk.AccelerationStructureInstanceKHR));
    defer sync_copier.destroy(&context);

    std.log.info("Set up initial state!", .{});

    try encoder.begin();
    var scene = try Scene.fromGltfExr(&context, allocator, &encoder, config.in_filepath, config.skybox_filepath, config.extent);
    defer scene.destroy(&context, allocator);
    try encoder.submitAndIdleUntilDone(&context);

    std.log.info("Loaded scene!", .{});

    try encoder.begin();

    var object_picker = try ObjectPicker.create(&context, allocator, &encoder);
    defer object_picker.destroy(&context);

    var spec_constants = Pipeline.SpecConstants {};
    var pipeline = try Pipeline.create(&context, allocator, &encoder, .{ scene.world.materials.textures.descriptor_layout.handle, scene.world.constant_specta.descriptor_layout.handle }, spec_constants, .{ scene.background.sampler });
    defer pipeline.destroy(&context);

    var gui = try Platform.create(&context, display.swapchain, window, window_extent, &encoder);
    defer gui.destroy(&context);

    try encoder.submitAndIdleUntilDone(&context);

    std.log.info("Created pipelines!", .{});

    // random state we need for gui
    var active_sensor: u32 = 0;
    var active_camera: u32 = 0;
    var max_sample_count: u32 = 0; // unlimited
    var navigation_speed: f32 = 10;
    var rebuild_label_buffer: [20]u8 = undefined;
    var rebuild_label = try std.fmt.bufPrintZ(&rebuild_label_buffer, "Rebuild", .{});
    var rebuild_error = false;
    var has_clicked = false;
    var current_clicked_object: ?ObjectPicker.ClickedObject = null;
    var current_clicked_color = F32x3.new(0.0, 0.0, 0.0);

    while (!window.shouldClose()) {
        var frame_encoder = if (display.startFrame(&context)) |buffer| buffer else |err| switch (err) {
            error.OutOfDateKHR => blk: {
                const new_extent = window.getExtent();
                context.device.destroySwapchainKHR(try display.recreate(&context, new_extent), null);
                try gui.resize(&context, display.swapchain);
                scene.camera.sensors.items[active_sensor].destroy(&context);
                scene.camera.sensors.items.len -= 1;
                active_sensor = try scene.camera.appendSensor(&context, allocator, new_extent);
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
                scene.camera.sensors.items[active_sensor].clear();
            }
            imgui.sameLine();
            try imgui.textFmt("Sample count: {}", .{scene.camera.sensors.items[active_sensor].sample_count});
            imgui.pushItemWidth(imgui.getFontSize() * -10);
            _ = imgui.inputScalar(u32, "Max sample count", &max_sample_count, 1, 100);
            imgui.popItemWidth();
        }
        if (imgui.collapsingHeader("Camera")) {
            imgui.pushItemWidth(imgui.getFontSize() * -7.5);
            var changed = blk: {
                const before = active_camera;
                if (imgui.beginCombo("Active Camera", scene.camera.cameras.items[active_camera][0])) {
                    for (0..scene.camera.cameras.items.len) |camera| {
                        const selected = active_camera == camera;
                        if (imgui.selectable(scene.camera.cameras.items[camera][0], selected)) active_camera = @intCast(camera);
                        if (selected) imgui.setItemDefaultFocus();
                    }
                    imgui.endCombo();
                }
                break :blk before != active_camera;
            };
            changed = imgui.enumCombo(Camera.Model, "Camera Model", &scene.camera.cameras.items[active_camera][1].model) or changed;
            switch (scene.camera.cameras.items[active_camera][1].model) {
                .thin_lens => {
                    changed = imgui.sliderAngle("Vertical FOV", &scene.camera.cameras.items[active_camera][1].thin_lens.vfov, 1, 179) or changed;
                    changed = imgui.dragScalar(f32, "Focus distance", &scene.camera.cameras.items[active_camera][1].thin_lens.focus_distance, 0.1, -std.math.inf(f32), std.math.inf(f32)) or changed;
                    changed = imgui.dragScalar(f32, "Aperture size", &scene.camera.cameras.items[active_camera][1].thin_lens.aperture, 0.01, 0.0, std.math.inf(f32)) or changed;
                },
                .orthographic => {
                    changed = imgui.dragScalar(f32, "Vertical Scale", &scene.camera.cameras.items[active_camera][1].orthographic.vscale, 0.1, 0, std.math.inf(f32)) or changed;
                },
            }
            if (changed) {
                scene.camera.sensors.items[active_sensor].clear();
            }
            imgui.popItemWidth();
        }
        if (imgui.collapsingHeader("Integrator")) {
            imgui.pushItemWidth(imgui.getFontSize() * -14.2);
            _ = imgui.enumCombo(hrtsystem.pipeline.Integrator, "Type", &spec_constants.integrator);
            switch (spec_constants.integrator) {
                .direct_lighting => {
                    _ = imgui.dragScalar(u32, "Environment Map Samples", &spec_constants.direct_lighting_env_samples, 1.0, 0, std.math.maxInt(u32));
                    _ = imgui.dragScalar(u32, "Mesh Samples", &spec_constants.direct_lighting_mesh_samples, 1.0, 0, std.math.maxInt(u32));
                    _ = imgui.dragScalar(u32, "BRDF Samples", &spec_constants.direct_lighting_brdf_samples, 1.0, 0, std.math.maxInt(u32));
                },
                .path_tracing => {
                    _ = imgui.dragScalar(u32, "Environment Map Samples", &spec_constants.path_tracing_env_samples_per_bounce, 1.0, 0, std.math.maxInt(u32));
                    _ = imgui.dragScalar(u32, "Mesh Samples", &spec_constants.path_tracing_mesh_samples_per_bounce, 1.0, 0, std.math.maxInt(u32));
                    _ = imgui.dragScalar(u32, "Russian Roulette Depth", &spec_constants.path_tracing_russian_roulette_depth, 1.0, 0, std.math.maxInt(u32));
                },
                .volume_path_tracing => {
                    _ = imgui.dragScalar(u32, "Environment Map Samples", &spec_constants.volume_path_tracing_env_samples_per_bounce, 1.0, 0, std.math.maxInt(u32));
                    _ = imgui.dragScalar(u32, "Mesh Samples", &spec_constants.volume_path_tracing_mesh_samples_per_bounce, 1.0, 0, std.math.maxInt(u32));
                    _ = imgui.dragScalar(u32, "Russian Roulette Depth", &spec_constants.volume_path_tracing_russian_roulette_depth, 1.0, 0, std.math.maxInt(u32));
                }
            }
            const last_rebuild_failed = rebuild_error;
            if (last_rebuild_failed) imgui.pushStyleColor(.text, F32x4.new(1.0, 0.0, 0.0, 1));
            if (imgui.button(rebuild_label, imgui.Vec2{ .x = imgui.getContentRegionAvail().x, .y = 0.0 })) {
                const start = try std.time.Instant.now();
                rebuild_error = false;
                try encoder.begin();
                if (pipeline.recreate(&context, allocator, &encoder, spec_constants)) |old_pipeline| {
                    try frame_encoder.attachResource(old_pipeline);
                    scene.camera.sensors.items[active_sensor].clear();
                } else |err| if (err == error.ShaderCompileFail) {
                    rebuild_error = true;
                } else return err;
                try encoder.submitAndIdleUntilDone(&context);
                if (!rebuild_error) {
                    const elapsed = (try std.time.Instant.now()).since(start) / std.time.ns_per_ms;
                    rebuild_label = try std.fmt.bufPrintZ(&rebuild_label_buffer, "Rebuild ({d}ms)", .{elapsed});
                } else {
                    rebuild_label = try std.fmt.bufPrintZ(&rebuild_label_buffer, "Rebuild (error)", .{});
                }
            }
            if (!core.pipeline.supports_hot_reload) imgui.setItemTooltip("Shader hot reload not available");
            if (last_rebuild_failed) imgui.popStyleColor();
            imgui.popItemWidth();
        }
        imgui.end();
        imgui.setNextWindowPos(@as(f32, @floatFromInt(@max(display.swapchain.extent.width, 50) - 50)) - 350, 50);
        imgui.setNextWindowSize(350, 450);
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
                const instance = try sync_copier.copyBufferItem(&context, vk.AccelerationStructureInstanceKHR, scene.world.accel.instances_device.handle, object.instance_index);
                const accel_geometry_index = instance.instance_custom_index_and_mask.instance_custom_index + object.geometry_index;
                var geometry = try sync_copier.copyBufferItem(&context, Accel.Geometry, scene.world.accel.geometries.handle, accel_geometry_index);
                var material = try sync_copier.copyBufferItem(&context, MaterialManager.GpuMaterial, scene.world.materials.materials.handle, geometry.material);
                try imgui.textFmt("Mesh index: {d}", .{geometry.mesh});
                if (imgui.inputScalar(u32, "Material index", &geometry.material, null, null) and geometry.material < scene.world.materials.material_count) {
                    scene.world.accel.recordUpdateSingleMaterial(frame_encoder.buffer, accel_geometry_index, geometry.material);
                    scene.camera.sensors.items[active_sensor].clear();
                }
                imgui.separatorText("mesh");
                const mesh = scene.world.meshes.meshes.get(geometry.mesh);
                try imgui.textFmt("Vertex count: {d}", .{mesh.vertex_count});
                try imgui.textFmt("Index count: {d}", .{mesh.index_count});
                try imgui.textFmt("Has texcoords: {}", .{!mesh.texcoord_buffer.isNull()});
                try imgui.textFmt("Has normals: {}", .{!mesh.normal_buffer.isNull()});
                imgui.separatorText("material");
                {
                    var changed = false;
                    changed = imgui.dragScalar(u32, "normal", &material.normal, 1, 0, std.math.maxInt(u32)) or changed;
                    changed = imgui.dragScalar(u32, "emissive", &material.emissive, 1, 0, std.math.maxInt(u32)) or changed;
                    changed = exposeToImguiRecursive(MaterialManager.Volume, &material.volume, "volume") or changed;
                    if (changed) {
                        scene.world.materials.recordUpdateSingleMaterial(frame_encoder.buffer, geometry.material, material);
                        scene.camera.sensors.items[active_sensor].clear();
                    }
                }
                inline for (@typeInfo(MaterialManager.BSDF).@"enum".fields, @typeInfo(MaterialManager.PolymorphicBSDF).@"union".fields) |enum_field, union_field| {
                    const VariantType = union_field.type;
                    if (VariantType != void and enum_field.value == @intFromEnum(material.type)) {
                        const variant_idx: u32 = @intCast((material.addr - @field(scene.world.materials.variant_buffers, enum_field.name).addr) / @sizeOf(VariantType));
                        var material_variant = try sync_copier.copyBufferItem(&context, VariantType, @field(scene.world.materials.variant_buffers, enum_field.name).buffer.handle, variant_idx);
                        if (exposeToImguiRecursive(VariantType, &material_variant, @tagName(material.type))) {
                            scene.world.materials.recordUpdateSingleVariant(VariantType, frame_encoder.buffer, variant_idx, material_variant);
                            scene.camera.sensors.items[active_sensor].clear();
                        }
                    }
                }
                {
                    imgui.separatorText("instance");
                    const visible = instance.instance_custom_index_and_mask.mask != 0b00000000;
                    var thin = instance.instance_custom_index_and_mask.mask == 0b10000000;
                    var changed = false;
                    changed = imgui.checkbox("Thin", &thin) or changed;
                    const old_transform: Mat3x4 = @bitCast(instance.transform);
                    var translation = old_transform.extractTranslation();
                    imgui.pushItemWidth(imgui.getFontSize() * -6);
                    changed = imgui.dragVector(F32x3, "Translation", &translation, 0.1, -std.math.inf(f32), std.math.inf(f32)) or changed;
                    if (changed) {
                        scene.world.accel.recordUpdateSingleInstanceProperties(frame_encoder, object.instance_index, old_transform.withTranslation(translation), thin, visible);
                        try scene.world.accel.recordRebuild(frame_encoder.buffer);
                        scene.camera.sensors.items[active_sensor].clear();
                    }
                }
            }
            imgui.popItemWidth();
        } else {
            imgui.text("Go click something!");
        }
        imgui.end();
        if (!imgui.getIO().WantCaptureMouse) {
            const window_size = F32x2.new(
                @as(f32, @floatFromInt(display.swapchain.extent.width)),
                @as(f32, @floatFromInt(display.swapchain.extent.height))
            );
            if (imgui.isMouseDragging(.right)) {
                window.setCursorMode(.disabled);
                const delta = imgui.getMouseDragDelta(.right).componentDiv(window_size);
                imgui.resetMouseDragDelta(.right);
                if (!std.meta.eql(delta, F32x2.new(0.0, 0.0))) {
                    const left_right = Mat3.fromAxisAngle(F32x3.new(0, 0, 1), delta.x);
                    const up_down = Mat3.fromAxisAngle(F32x3.new(0, -1, 0), delta.y);
                    const rotation = up_down.mul(left_right);
                    scene.camera.cameras.items[active_camera][1].transform = scene.camera.cameras.items[active_camera][1].transform.mul(Mat3x4.fromTransformTranslation(rotation, F32x3.zero));
                    scene.camera.sensors.items[active_sensor].clear();
                }
            } else {
                window.setCursorMode(.normal);
                if (imgui.isMouseClicked(.left)) {
                    current_clicked_object = try object_picker.getClickedObject(&context, scene.world.accel.tlas_handle, imgui.getMousePos().componentDiv(window_size), scene.camera.cameras.items[active_camera][1], scene.camera.sensors.items[active_sensor]);
                    const clicked_pixel = try sync_copier.copyImagePixel(&context, F32x4, scene.camera.sensors.items[active_sensor].image.handle, .transfer_src_optimal, vk.Offset3D { .x = @intFromFloat(imgui.getMousePos().x), .y = @intFromFloat(imgui.getMousePos().y), .z = 0 });
                    current_clicked_color = clicked_pixel.truncate();
                    has_clicked = true;
                }
            }
            navigation_speed *= std.math.pow(f32, 1.1, imgui.getIO().MouseWheel);
        }
        if (!imgui.getIO().WantCaptureKeyboard) {
            var transform = scene.camera.cameras.items[active_camera][1].transform;

            const left = transform.mulVector(F32x3.new(0, -1, 0));
            const forward = transform.mulVector(F32x3.new(1, 0, 0));
            const origin = transform.extractTranslation();

            const speed = imgui.getIO().DeltaTime;

            if (imgui.isKeyDown(.w)) transform = transform.withTranslation(origin.add(forward.scale(speed * navigation_speed)));
            if (imgui.isKeyDown(.s)) transform = transform.withTranslation(origin.sub(forward.scale(speed * navigation_speed)));
            if (imgui.isKeyDown(.a)) transform = transform.withTranslation(origin.add(left.scale(speed * navigation_speed)));
            if (imgui.isKeyDown(.d)) transform = transform.withTranslation(origin.sub(left.scale(speed * navigation_speed)));

            if (!std.meta.eql(transform, scene.camera.cameras.items[active_camera][1].transform)) {
                scene.camera.cameras.items[active_camera][1].transform = transform;
                scene.camera.sensors.items[active_sensor].clear();
            }
        }

        if (max_sample_count != 0 and scene.camera.sensors.items[active_sensor].sample_count > max_sample_count) scene.camera.sensors.items[active_sensor].clear();
        if (max_sample_count == 0 or scene.camera.sensors.items[active_sensor].sample_count < max_sample_count) {
            scene.camera.sensors.items[active_sensor].recordPrepareForCapture(frame_encoder.buffer, .{ .ray_tracing_shader_bit_khr = true }, .{ .blit_bit = true });
            pipeline.recordBindPipeline(frame_encoder.buffer);
            pipeline.recordBindAdditionalDescriptorSets(frame_encoder.buffer, .{ scene.world.materials.textures.descriptor_set, scene.world.constant_specta.descriptor_set });
            pipeline.recordPushDescriptors(frame_encoder.buffer, scene.pushDescriptors(active_sensor, 0));
            pipeline.recordPushConstants(frame_encoder.buffer, .{ .camera = scene.camera.cameras.items[active_camera][1], .aspect_ratio = scene.camera.sensors.items[active_sensor].aspectRatio(), .sample_count = scene.camera.sensors.items[active_sensor].sample_count });
            pipeline.recordTraceRays(frame_encoder.buffer, scene.camera.sensors.items[active_sensor].extent);
            scene.camera.sensors.items[active_sensor].recordPrepareForCopy(frame_encoder.buffer, .{ .ray_tracing_shader_bit_khr = true }, .{ .blit_bit = true });
        }

        // transition swap image to one we can blit to
        frame_encoder.barrier(&[_]Encoder.ImageBarrier {
            Encoder.ImageBarrier {
                .src_stage_mask = .{ .color_attachment_output_bit = true },
                .src_access_mask = .{ .color_attachment_read_bit = true },
                .dst_stage_mask = .{ .blit_bit = true },
                .dst_access_mask = .{ .transfer_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .transfer_dst_optimal,
                .image = display.swapchain.currentImage(),
            }
        }, &.{});

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
                .x = @as(i32, @intCast(scene.camera.sensors.items[active_sensor].extent.width)),
                .y = @as(i32, @intCast(scene.camera.sensors.items[active_sensor].extent.height)),
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

        frame_encoder.buffer.blitImage(scene.camera.sensors.items[active_sensor].image.handle, .transfer_src_optimal, display.swapchain.currentImage(), .transfer_dst_optimal, 1, @ptrCast(&region), .nearest);
        frame_encoder.barrier(&[_]Encoder.ImageBarrier {
            Encoder.ImageBarrier {
                .src_stage_mask = .{ .blit_bit = true },
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_access_mask = .{ .color_attachment_read_bit = true },
                .old_layout = .transfer_dst_optimal,
                .new_layout = .color_attachment_optimal,
                .image = display.swapchain.currentImage(),
            }
        }, &.{});

        gui.endFrame(frame_encoder.buffer, display.swapchain.image_index, display.frame_index);

        // transition swapchain back to present mode
        frame_encoder.barrier(&[_]Encoder.ImageBarrier {
            Encoder.ImageBarrier {
                .src_stage_mask = .{ .color_attachment_output_bit = true },
                .src_access_mask = .{ .color_attachment_write_bit = true },
                .dst_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_access_mask = .{},
                .old_layout = .color_attachment_optimal,
                .new_layout = .present_src_khr,
                .image = display.swapchain.currentImage(),
            }
        }, &.{});

        if (display.endFrame(&context)) |ok| {
            // only update frame count if we presented successfully
            scene.camera.sensors.items[active_sensor].sample_count += 1;
            if (max_sample_count != 0) scene.camera.sensors.items[active_sensor].sample_count = @min(scene.camera.sensors.items[active_sensor].sample_count, max_sample_count);
            if (ok == vk.Result.suboptimal_khr) {
                const new_extent = window.getExtent();
                try frame_encoder.attachResource(try display.recreate(&context, new_extent));
                try gui.resize(&context, display.swapchain);
                try frame_encoder.attachResource(scene.camera.sensors.items[active_sensor].image);
                scene.camera.sensors.items.len -= 1;
                active_sensor = try scene.camera.appendSensor(&context, allocator, new_extent);
            }
        } else |err| if (err == error.OutOfDateKHR) {
            const new_extent = window.getExtent();
            try frame_encoder.attachResource(try display.recreate(&context, new_extent));
            try gui.resize(&context, display.swapchain);
            try frame_encoder.attachResource(scene.camera.sensors.items[active_sensor].image);
            scene.camera.sensors.items.len -= 1;
            active_sensor = try scene.camera.appendSensor(&context, allocator, new_extent);
        } else return err;

        window.pollEvents();
    }
    try context.device.deviceWaitIdle();

    std.log.info("Program completed!", .{});
}

pub fn exposeToImguiRecursive(T: type, value: *T, name: [:0]const u8) bool {
    var changed = false;
    if (imgui.treeNode(name)) {
        inline for (@typeInfo(T).@"struct".fields) |struct_field| {
            changed = switch (struct_field.type) {
                f32 => imgui.dragScalar(f32, struct_field.name.ptr, &@field(value, struct_field.name), 0.01, 0, std.math.inf(f32)),
                u32 => imgui.dragScalar(u32, struct_field.name.ptr, &@field(value, struct_field.name), 1, 0, std.math.maxInt(u32)),
                else => if (@hasDecl(struct_field.type, "ComponentType")) switch (struct_field.type.ComponentType) {
                    f32 => imgui.dragVector(struct_field.type, struct_field.name.ptr, &@field(value, struct_field.name), 0.01, 0, std.math.inf(f32)),
                    u32 => imgui.dragVector(struct_field.type, struct_field.name.ptr, &@field(value, struct_field.name), 1, 0, std.math.maxInt(u32)),
                    else => unreachable,
                } else exposeToImguiRecursive(struct_field.type, &@field(value, struct_field.name), struct_field.name),
            } or changed;
        }
        imgui.treePop();
    }
    return changed;
}