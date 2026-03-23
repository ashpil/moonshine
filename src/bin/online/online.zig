const std = @import("std");

const engine = @import("engine");

const shaders = @import("shaders");

const ObjectPicker = @import("ObjectPicker.zig");
const SyncCopier = @import("SyncCopier.zig");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const DestructionQueue = core.DestructionQueue;
const vk_helpers = core.vk_helpers;
const Image = core.Image;

const hrtsystem = engine.hrtsystem;
const Camera = hrtsystem.CameraManager;
const Accel = hrtsystem.Accel;
const ModelManager = hrtsystem.ModelManager;
const MaterialManager = hrtsystem.MaterialManager;
const Scene = hrtsystem.Scene;
const RenderPipeline = hrtsystem.pipeline.Render;

const displaysystem = engine.displaysystem;
const Display = displaysystem.Display;
const Window = engine.Window;
const Platform = engine.gui.Platform;
const imgui = engine.gui.imgui;

const vector = engine.vector;
const F32x4 = vector.Vec4(f32);
const F32x3 = vector.Vec3(f32);
const F32x2 = vector.Vec2(f32);
const F64x4 = vector.Vec4(f64);
const F64x3 = vector.Vec3(f64);
const F64x2 = vector.Vec2(f64);
const U8x4 = vector.Vec4(u8);
const U8x3 = vector.Vec3(u8);
const F32x3x3 = vector.Mat3(f32);
const F32x2x2 = vector.Mat2(f32);
const F32x4x3 = vector.Mat4x3(f32);
const F64x3x3 = vector.Mat3(f64);
const F64x2x2 = vector.Mat2(f64);

const vk = @import("vulkan");

fn createVulkanContext(allocator: std.mem.Allocator, window: Window) !std.meta.Tuple(&.{ VulkanContext, bool }) {
    const base_requirements = comptime hrtsystem.vulkan_requirements.merge(displaysystem.vulkan_requirements);
    const needed_instance_extensions = window.getRequiredInstanceExtensions();
    const wanted_instance_extensions = [_][*:0]const u8 { vk.extensions.ext_swapchain_colorspace.name };
    var needed_requirements = base_requirements;
    needed_requirements.instance_extensions = base_requirements.instance_extensions ++ &needed_instance_extensions;
    var wanted_requirements = base_requirements;
    wanted_requirements.instance_extensions = base_requirements.instance_extensions ++ &needed_instance_extensions ++ &wanted_instance_extensions;
    // this is super ugly but I don't currently want to write something that allows the context to give feedback on what extensions were enabled
    return if (VulkanContext.create(allocator, "online", wanted_requirements)) |context| .{ context, true } else |err| switch (err) {
        VulkanContext.VulkanContextError.UnavailableInstanceExtensions => .{ try VulkanContext.create(allocator, "online", needed_requirements), false },
        else => return err,
    };
}

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
            .extent = vk.Extent2D{ .width = 1600, .height = 900 }, // TODO: cli
        };
    }

    fn destroy(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.in_filepath);
        allocator.free(self.skybox_filepath);
    }
};

const PostProcessPipeline = core.pipeline.Pipeline(.{
    .local_size = vk.Extent3D { .width = 8, .height = 8, .depth = 1 },
    .shader_source = shaders.post_process,
    .PushConstants = extern struct {
        src_image_scene_referred_to_display_referred_scale: f32 = 1.0,
        src_chromaticities_to_xyz: F32x3x3,
        dst_white_encoding: f32,
        dst_chromaticities_from_xyz: F32x3x3,
        dst_transfer_function: engine.color.TransferFunction,
    },
    .PushSetBindings = struct {
        src_image: core.pipeline.SampledImage,
        overlay_image: core.pipeline.SampledImage,
        dst_image: core.pipeline.StorageImage,
    },
});


pub fn main() !void {
    var gpa = engine.Allocator.init();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try Config.fromCli(allocator);
    defer config.destroy(allocator);

    const window = try Window.create(config.extent.width, config.extent.height, "online");
    defer window.destroy();

    const context, const supports_swapchain_color_spaces = try createVulkanContext(allocator, window);
    defer context.destroy(allocator);

    run(allocator, context, config, window, supports_swapchain_color_spaces) catch |err| {
        if (err == error.DeviceLost) try context.handleDeviceLost(allocator);
        return err;
    };
}

fn run(allocator: std.mem.Allocator, context: VulkanContext, config: Config, window: Window, supports_swapchain_color_spaces: bool) !void {
    var display = try Display.create(&context, window, supports_swapchain_color_spaces, allocator);
    defer display.destroy(&context, allocator);

    var encoder = try Encoder.create(&context, "main");
    defer encoder.destroy(&context);

    var sync_copier = try SyncCopier.create(&context, @sizeOf(vk.AccelerationStructureInstanceKHR));
    defer sync_copier.destroy(&context);

    std.log.info("Set up initial state!", .{});

    try encoder.begin();
    var scene = try Scene.fromGltfExr(&context, allocator, &encoder, config.in_filepath, config.skybox_filepath, config.extent, engine.color.Chromaticities.fromVkColorspace(display.swapchain.color_space));
    defer scene.destroy(&context, allocator);
    try encoder.submitAndIdleUntilDone(&context);

    std.log.info("Loaded scene!", .{});

    var object_picker = try ObjectPicker.create(&context, allocator);
    defer object_picker.destroy(&context);

    var spec_constants = RenderPipeline.SpecConstants {};
    var render_pipeline = try RenderPipeline.create(&context, allocator, spec_constants, .{ scene.background.equal_area_sampler }, .{ scene.world.materials.textures.descriptor_layout.handle, scene.world.constant_spectra.descriptor_layout.handle });
    defer render_pipeline.destroy(&context);

    var post_process_pipeline = try PostProcessPipeline.create(&context, allocator, .{}, .{}, .{});
    defer post_process_pipeline.destroy(&context);

    const gui_format = .r8g8b8a8_unorm;
    var gui_image = try Image.create(&context, window.getExtent(), .{ .color_attachment_bit = true, .sampled_bit = true, }, gui_format, false, "gui image");
    defer gui_image.destroy(&context);

    try encoder.begin();

    var gui = try Platform.create(&context, gui_format, window, &encoder);
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
    var current_clicked_color = F32x3.new(.{0.0, 0.0, 0.0});
    var frame_index: u32 = 0;
    var gui_open: bool = true;
    var scene_referred_to_display_referred_scale: f32 = 1.0;

    while (!window.shouldClose()) {
        var frame_encoder = if (display.startFrame(&context)) |buffer| buffer else |err| switch (err) {
            error.OutOfDateKHR => blk: {
                // presentation failed, can destroy resources immediately
                (try display.recreate(&context, window, supports_swapchain_color_spaces, allocator)).destroy(&context, allocator);
                scene.camera.sensors.items[active_sensor].image.destroy(&context);
                gui_image.destroy(&context);
                scene.camera.sensors.items.len -= 1;
                active_sensor = try scene.camera.appendSensor(&context, allocator, display.swapchain.extent, engine.color.Chromaticities.fromVkColorspace(display.swapchain.color_space));
                gui_image = try Image.create(&context, display.swapchain.extent, .{ .color_attachment_bit = true, .sampled_bit = true, }, gui_format, false, "gui image");
                break :blk try display.startFrame(&context); // don't recreate on second failure
            },
            else => return err,
        };

        gui.startFrame();

        if (gui_open) {
            imgui.setNextWindowPos(50, 50);
            imgui.setNextWindowSize(250, 350);
            imgui.begin("Settings");
            if (imgui.collapsingHeader("Performance")) {
                try imgui.textFmt("Last frame time: {d:.3}ms", .{display.last_frame_time_ns / std.time.ns_per_ms});
                try imgui.textFmt("Framerate: {d:.2} FPS", .{imgui.getIO().Framerate});
            }
            if (imgui.collapsingHeader("Display")) {
                try imgui.textFmt("Color space: {s}", .{@tagName(display.swapchain.color_space)});
                drawChromaticityDiagram(engine.color.Chromaticities.fromVkColorspace(display.swapchain.color_space));
                _ = imgui.dragScalar(f32, "Scene Referred To Display Referred Scale", &scene_referred_to_display_referred_scale, scene_referred_to_display_referred_scale / 10.0, 0.0001, std.math.inf(f32));
            }
            if (imgui.collapsingHeader("Scene")) {
                try imgui.textFmt("Texture count: {}", .{scene.world.materials.textures.data.len});
                try imgui.textFmt("Material count: {}", .{scene.world.materials.material_count});
                try imgui.textFmt("Mesh count: {}", .{scene.world.meshes.host.len});
                try imgui.textFmt("Model count: {}", .{scene.world.models.models_host.len});
                try imgui.textFmt("Instance count: {}", .{scene.world.accel.instance_count});
                if (exposeToImguiRecursive(MaterialManager.Volume, &scene.global_volume, "Global volume")) {
                    scene.camera.sensors.items[active_sensor].clear();
                }
            }
            if (imgui.collapsingHeader("Sensor")) {
                if (imgui.button("Reset", imgui.Vec2{ .x = imgui.getContentRegionAvail().element(0) - imgui.getFontSize() * 10, .y = 0 })) {
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
                changed = imgui.dragMatrix(F32x4x3, "Transform", &scene.camera.cameras.items[active_camera][1].transform, 0.1, -std.math.inf(f32), std.math.inf(f32)) or changed;
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
                if (last_rebuild_failed) imgui.pushStyleColor(.text, F32x4.new(.{1.0, 0.0, 0.0, 1}));
                if (imgui.button(rebuild_label, imgui.Vec2{ .x = imgui.getContentRegionAvail().element(0), .y = 0.0 })) {
                    const start = try std.time.Instant.now();
                    rebuild_error = false;
                    if (render_pipeline.recreate(&context, allocator, spec_constants)) |old_pipeline| {
                        try frame_encoder.attachResource(old_pipeline);
                        scene.camera.sensors.items[active_sensor].clear();
                    } else |err| if (err == error.ShaderCompileFail) {
                        rebuild_error = true;
                    } else return err;
                    if (!rebuild_error) {
                        const elapsed = (try std.time.Instant.now()).since(start) / std.time.ns_per_ms;
                        rebuild_label = try std.fmt.bufPrintZ(&rebuild_label_buffer, "Rebuild ({d}ms)", .{elapsed});
                    } else {
                        rebuild_label = try std.fmt.bufPrintZ(&rebuild_label_buffer, "Rebuild (error)", .{});
                    }
                }
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
                    const model = try sync_copier.copyBufferItem(&context, ModelManager.Model.Device, scene.world.models.models_device.handle, instance.instance_custom_index_and_mask.instance_custom_index);
                    const accel_geometry_index = model.geometry_offset + object.geometry_index;
                    var geometry = try sync_copier.copyBufferItem(&context, ModelManager.Geometry.Device, scene.world.models.geometries_device.handle, accel_geometry_index);
                    var material = try sync_copier.copyBufferItem(&context, MaterialManager.Material.Device, scene.world.materials.materials.handle, geometry.material);
                    try imgui.textFmt("Mesh index: {d}", .{geometry.mesh});
                    if (imgui.inputScalar(u32, "Material index", &geometry.material, null, null) and geometry.material < scene.world.materials.material_count) {
                        scene.world.models.recordUpdateSingleMaterial(frame_encoder.buffer, accel_geometry_index, geometry.material);
                        scene.camera.sensors.items[active_sensor].clear();
                    }
                    imgui.separatorText("mesh");
                    const mesh = scene.world.meshes.host.get(geometry.mesh);
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
                        var priority: u8 = @intCast(if (thin) 1 else @ctz(instance.instance_custom_index_and_mask.mask) + 1);
                        var changed = false;
                        changed = imgui.checkbox("Thin", &thin) or changed;
                        if (thin) imgui.beginDisabled();
                        changed = imgui.dragScalar(u8, "Priority", &priority, 1, 1, 7) or changed;
                        if (thin) imgui.endDisabled();
                        var transform: F32x4x3 = @bitCast(instance.transform);
                        imgui.pushItemWidth(imgui.getFontSize() * -6);
                        changed = imgui.dragMatrix(F32x4x3, "Transform", &transform, 0.1, -std.math.inf(f32), std.math.inf(f32)) or changed;
                        if (changed) {
                            scene.world.accel.recordUpdateSingleInstanceProperties(frame_encoder, object.instance_index, transform, thin, @intCast(priority), visible);
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
        }
        if (!imgui.getIO().WantCaptureMouse) {
            const window_size = F32x2.new(.{
                @as(f32, @floatFromInt(display.swapchain.extent.width)),
                @as(f32, @floatFromInt(display.swapchain.extent.height))
            });
            if (imgui.isMouseDragging(.right)) {
                window.setCursorMode(.disabled);
                const delta = imgui.getMouseDragDelta(.right).componentDiv(window_size);
                imgui.resetMouseDragDelta(.right);
                if (!std.meta.eql(delta, F32x2.new(.{0.0, 0.0}))) {
                    const transform = scene.camera.cameras.items[active_camera][1].transform;
                    const transform_linear = transform.truncateCol();
                    const transform_translation = transform.col(3);
                    const left_right = F32x3x3.fromAxisAngle(F32x3.new(.{0, 1, 0}), -delta.element(0)); // should be global. assumes glTF which has +Y as up
                    const up_down = transform_linear.mul(F32x3x3.fromAxisAngle(.new(.{0, 1, 0}), -delta.element(1))); // should be local
                    scene.camera.cameras.items[active_camera][1].transform = left_right.mul(up_down).appendCol(transform_translation);
                    scene.camera.sensors.items[active_sensor].clear();
                }
            } else if (imgui.isMouseDragging(.middle)) {
                window.setCursorMode(.disabled);
                const delta = imgui.getMouseDragDelta(.middle).componentDiv(window_size);
                imgui.resetMouseDragDelta(.middle);
                if (!std.meta.eql(delta, F32x2.new(.{0.0, 0.0}))) {
                    const left_right = F32x3x3.fromAxisAngle(.new(.{0, 0, 1}), delta.element(0));
                    scene.background.backgrounds.items[0].transform = left_right.mul(scene.background.backgrounds.items[0].transform);
                    scene.camera.sensors.items[active_sensor].clear();
                }
            } else {
                window.setCursorMode(.normal);
                if (imgui.isMouseClicked(.left)) {
                    current_clicked_object = try object_picker.getClickedObject(&context, scene.world.accel.tlas_handle, imgui.getMousePos().componentDiv(window_size), scene.camera.cameras.items[active_camera][1], scene.camera.sensors.items[active_sensor]);
                    const clicked_pixel = try sync_copier.copyImagePixel(&context, F32x4, scene.camera.sensors.items[active_sensor].image.handle, vk.Offset3D { .x = @intFromFloat(imgui.getMousePos().element(0)), .y = @intFromFloat(imgui.getMousePos().element(1)), .z = 0 });
                    current_clicked_color = clicked_pixel.truncate();
                    has_clicked = true;
                }
            }
            navigation_speed *= std.math.pow(f32, 1.1, imgui.getIO().MouseWheel);
        }
        if (!imgui.getIO().WantCaptureKeyboard) {
            var transform = scene.camera.cameras.items[active_camera][1].transform;

            const left = transform.truncateCol().mul(F32x3.new(.{0, -1, 0}));
            const forward = transform.truncateCol().mul(F32x3.new(.{1, 0, 0}));
            const origin = transform.col(3);

            const boost: f32 = if (imgui.getIO().KeyShift) 5.0 else 1.0;
            const speed = imgui.getIO().DeltaTime * boost;

            if (imgui.isKeyDown(.w)) transform = transform.truncateCol().appendCol(origin.componentAdd(forward.scale(speed * navigation_speed)));
            if (imgui.isKeyDown(.s)) transform = transform.truncateCol().appendCol(origin.componentSub(forward.scale(speed * navigation_speed)));
            if (imgui.isKeyDown(.a)) transform = transform.truncateCol().appendCol(origin.componentAdd(left.scale(speed * navigation_speed)));
            if (imgui.isKeyDown(.d)) transform = transform.truncateCol().appendCol(origin.componentSub(left.scale(speed * navigation_speed)));

            if (!std.meta.eql(transform, scene.camera.cameras.items[active_camera][1].transform)) {
                scene.camera.cameras.items[active_camera][1].transform = transform;
                scene.camera.sensors.items[active_sensor].clear();
            }

            if (imgui.isKeyReleased(.escape)) {
                gui_open = !gui_open;
            }
        }

        if (max_sample_count != 0 and scene.camera.sensors.items[active_sensor].sample_count > max_sample_count) scene.camera.sensors.items[active_sensor].clear();
        if (max_sample_count == 0 or scene.camera.sensors.items[active_sensor].sample_count < max_sample_count) {
            frame_encoder.barrier(&[_]Encoder.ImageBarrier {
                Encoder.ImageBarrier {
                    .src_stage_mask = .{ .compute_shader_bit = true },
                    .src_access_mask = .{ .shader_sampled_read_bit = true },
                    .dst_stage_mask = .{ .compute_shader_bit = true },
                    .dst_access_mask = if (scene.camera.sensors.items[active_sensor].sample_count == 0) .{ .shader_storage_write_bit = true } else .{ .shader_storage_write_bit = true, .shader_storage_read_bit = true },
                    .old_layout = if (scene.camera.sensors.items[active_sensor].sample_count == 0) .undefined else .general,
                    .new_layout = .general,
                    .image = scene.camera.sensors.items[active_sensor].image.handle,
                }
            }, &.{});
            render_pipeline.recordBindPipeline(frame_encoder.buffer);
            render_pipeline.recordBindAdditionalDescriptorSets(frame_encoder.buffer, .{ scene.world.materials.textures.descriptor_set, scene.world.constant_spectra.descriptor_set });
            render_pipeline.recordPushDescriptors(frame_encoder.buffer, scene.pushDescriptors(active_camera, active_sensor, 0));
            render_pipeline.recordPushConstants(frame_encoder.buffer, scene.pushConstants(active_camera, active_sensor, 0, frame_index));
            render_pipeline.recordDispatchThreads2D(frame_encoder.buffer, scene.camera.sensors.items[active_sensor].extent);
        }

        // render gui into gui image
        frame_encoder.barrier(&[_]Encoder.ImageBarrier {
            Encoder.ImageBarrier {
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_sampled_read_bit = true },
                .dst_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_access_mask = .{ .color_attachment_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .general,
                .image = gui_image.handle,
            },
        }, &.{});
        gui.endFrame(frame_encoder.buffer, display.swapchain.extent, gui_image.view, display.frame_index);

        // post process rendered image and composite overlay onto swap image
        const swap_barrier = Encoder.ImageBarrier {
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{ .color_attachment_read_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_storage_write_bit = true },
            .old_layout = .undefined,
            .new_layout = .general,
            .image = display.currentImage().handle,
        };
        const sensor_barrier = Encoder.ImageBarrier {
            .src_stage_mask = .{ .compute_shader_bit = true },
            .src_access_mask = if (scene.camera.sensors.items[active_sensor].sample_count == 0) .{ .shader_storage_write_bit = true } else .{ .shader_storage_write_bit = true, .shader_storage_read_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_storage_read_bit = true },
            .image = scene.camera.sensors.items[active_sensor].image.handle,
        };
        const gui_barrier = Encoder.ImageBarrier {
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{ .color_attachment_write_bit = true },
            .dst_stage_mask = .{ .compute_shader_bit = true },
            .dst_access_mask = .{ .shader_sampled_read_bit = true },
            .image = gui_image.handle,
        };
        frame_encoder.barrier(if (max_sample_count == 0 or scene.camera.sensors.items[active_sensor].sample_count < max_sample_count) &[_]Encoder.ImageBarrier { swap_barrier, gui_barrier, sensor_barrier } else &[_]Encoder.ImageBarrier { swap_barrier, gui_barrier }, &.{});

        post_process_pipeline.recordBindPipeline(frame_encoder.buffer);
        post_process_pipeline.recordPushDescriptors(frame_encoder.buffer, PostProcessPipeline.PushSetBindings {
            .src_image = .{ .view = scene.camera.sensors.items[active_sensor].image.view },
            .overlay_image = .{ .view = gui_image.view },
            .dst_image = .{ .view = display.currentImage().view },
        });
        post_process_pipeline.recordPushConstants(frame_encoder.buffer, .{
            .src_image_scene_referred_to_display_referred_scale = scene_referred_to_display_referred_scale,
            .src_chromaticities_to_xyz = engine.color.Chromaticities.fromVkColorspace(display.swapchain.color_space).toXYZ().floatCast(f32),
            .dst_white_encoding = @floatCast(engine.color.TransferFunction.fromVkColorspace(display.swapchain.color_space).whiteEncoding()),
            .dst_chromaticities_from_xyz = engine.color.Chromaticities.fromVkColorspace(display.swapchain.color_space).fromXYZ().floatCast(f32),
            .dst_transfer_function = engine.color.TransferFunction.fromVkColorspace(display.swapchain.color_space),
        });
        post_process_pipeline.recordDispatchThreads2D(frame_encoder.buffer, scene.camera.sensors.items[active_sensor].extent);

        // transition swapchain back to present mode
        frame_encoder.barrier(&[_]Encoder.ImageBarrier {
            Encoder.ImageBarrier {
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_storage_write_bit = true },
                .dst_stage_mask = .{ .color_attachment_output_bit = true },
                .dst_access_mask = .{},
                .old_layout = .general,
                .new_layout = .present_src_khr,
                .image = display.currentImage().handle,
            }
        }, &.{});

        if (display.endFrame(&context)) |ok| {
            // only update frame count if we presented successfully
            scene.camera.sensors.items[active_sensor].sample_count += 1;
            if (max_sample_count != 0) scene.camera.sensors.items[active_sensor].sample_count = @min(scene.camera.sensors.items[active_sensor].sample_count, max_sample_count);
            if (ok == .suboptimal_khr or !std.meta.eql(window.getExtent(), display.swapchain.extent)) {
                // presentation succeeded, need to keep resources alive until frame finishes
                try (try display.recreate(&context, window, supports_swapchain_color_spaces, allocator)).attachToEncoder(frame_encoder, allocator);
                try frame_encoder.attachResource(scene.camera.sensors.items[active_sensor].image);
                try frame_encoder.attachResource(gui_image);
                scene.camera.sensors.items.len -= 1;
                active_sensor = try scene.camera.appendSensor(&context, allocator, display.swapchain.extent, engine.color.Chromaticities.fromVkColorspace(display.swapchain.color_space));
                gui_image = try Image.create(&context, display.swapchain.extent, .{ .color_attachment_bit = true, .sampled_bit = true, }, gui_format, false, "gui image");
            }
        } else |err| if (err == error.OutOfDateKHR) {
            // presentation failed, can destroy resources immediately
            (try display.recreate(&context, window, supports_swapchain_color_spaces, allocator)).destroy(&context, allocator);
            scene.camera.sensors.items[active_sensor].image.destroy(&context);
            gui_image.destroy(&context);
            scene.camera.sensors.items.len -= 1;
            active_sensor = try scene.camera.appendSensor(&context, allocator, display.swapchain.extent, engine.color.Chromaticities.fromVkColorspace(display.swapchain.color_space));
            gui_image = try Image.create(&context, display.swapchain.extent, .{ .color_attachment_bit = true, .sampled_bit = true, }, gui_format, false, "gui image");
        } else return err;

        window.pollEvents();
        frame_index += 1;
    }
    try context.device.deviceWaitIdle();

    std.log.info("Program completed!", .{});
}

pub fn exposeToImguiRecursive(T: type, value: *T, name: [:0]const u8) bool {
    var changed = false;
    if (imgui.treeNode(name)) {
        inline for (@typeInfo(T).@"struct".fields) |struct_field| {
            changed = switch (struct_field.type) {
                f32 => imgui.dragScalar(f32, struct_field.name.ptr, &@field(value, struct_field.name), 0.01, -std.math.inf(f32), std.math.inf(f32)),
                u32 => imgui.dragScalar(u32, struct_field.name.ptr, &@field(value, struct_field.name), 1, 0, std.math.maxInt(u32)),
                else => if (@hasDecl(struct_field.type, "ComponentType")) switch (struct_field.type.ComponentType) {
                    f32 => imgui.dragMatrix(struct_field.type, struct_field.name.ptr, &@field(value, struct_field.name), 0.01, -std.math.inf(f32), std.math.inf(f32)),
                    u32 => imgui.dragMatrix(struct_field.type, struct_field.name.ptr, &@field(value, struct_field.name), 1, 0, std.math.maxInt(u32)),
                    else => unreachable,
                } else exposeToImguiRecursive(struct_field.type, &@field(value, struct_field.name), struct_field.name),
            } or changed;
        }
        imgui.treePop();
    }
    return changed;
}

// the shape here is correct, but the inner fill colors are terrible
// doing better would require creating a texture, which is annoying,
// or a custom draw shader, also annoying
fn drawChromaticityDiagram(chromaticities: engine.color.Chromaticities) void {
    const color = engine.color;

    const samples_start = 435;
    const samples_end = 645;
    const sample_count = 200;

    var spectral_line: [sample_count]F64x3 = undefined;

    for (0..sample_count) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sample_count));
        const lambda = samples_start + t * (samples_end - samples_start);
        spectral_line[i] = color.wavelengthToXYZ(lambda);
    }

    const available_size = imgui.getContentRegionAvail();
    const canvas_size = F64x2.splat(@floatCast(available_size.element(0)));

    const canvas_start = imgui.getCursorScreenPos().floatCast(f64);
    const canvas_end = canvas_start.componentAdd(canvas_size);

    const draw_list = imgui.getWindowDrawList();

    imgui.addRect(draw_list, canvas_start.floatCast(f32), canvas_end.floatCast(f32), U8x4.splat(255), 0, 0, 1);

    imgui.primReserve(draw_list, spectral_line.len * 3, spectral_line.len + 1);

    var points_max = F64x2.splat(0);
    for (spectral_line) |point| {
        points_max = points_max.componentMax(color.XYZToxyY(point).truncate());
    }

    const padding = F64x2.splat(0.01);
    const normalize_mat = F64x2x2.diagonal(F64x2.splat(1).componentDiv(points_max.componentAdd(padding)).toArray()).appendCol(.splat(0)).appendRow(.new(.{0, 0, 1}));
    const flip_mat = F64x2x2.diagonal([2]f64{1, -1}).appendCol(.new(.{0, 1})).appendRow(.new(.{0, 0, 1}));
    const scale_mat = F64x2x2.diagonal(canvas_size.toArray()).appendCol(canvas_start).appendRow(.new(.{0, 0, 1}));
    const xy_to_view = scale_mat.mul(flip_mat).mul(normalize_mat);

    for (0..spectral_line.len) |i| {
    const start: imgui.DrawIdx = @intCast(draw_list._VtxCurrentIdx);
        imgui.primWriteIdx(draw_list, start + @as(imgui.DrawIdx, @intCast(i + 0)));
        imgui.primWriteIdx(draw_list, start + @as(imgui.DrawIdx, @intCast((i + 1) % spectral_line.len)));
        imgui.primWriteIdx(draw_list, start + @as(imgui.DrawIdx, @intCast(spectral_line.len)));
    }

    const points = spectral_line ++ [_]F64x3 { F64x3.splat(1.0) };
    for (points) |point| {
        const rgb = engine.color.Chromaticities.bt709.fromXYZ().mul(point).componentClamp(F64x3.splat(0.0), F64x3.splat(1.0));
        const rgb_scaled = rgb.scale(@floatFromInt(std.math.maxInt(u8)));
        const rgb_u8 = rgb_scaled.intFromFloat(u8).append(255);

        const xy = color.XYZToxyY(point).truncate();
        imgui.primWriteVtx(draw_list, xy_to_view.mul(xy.append(1)).truncate().floatCast(f32), @bitCast(imgui.getIO().Fonts.*.TexUvWhitePixel), rgb_u8);
    }

    imgui.addTriangle(draw_list,
        xy_to_view.mul(chromaticities.red.append(1)).truncate().floatCast(f32),
        xy_to_view.mul(chromaticities.green.append(1)).truncate().floatCast(f32),
        xy_to_view.mul(chromaticities.blue.append(1)).truncate().floatCast(f32),
    U8x3.splat(0).append(255));

    imgui.addCircle(draw_list, xy_to_view.mul(chromaticities.white.append(1)).truncate().floatCast(f32), @floatCast(xy_to_view.mul(F64x2.splat(1.0 / 64.0).append(0)).element(0)), U8x3.splat(0).append(255));

    imgui.setCursorScreenPos(F32x2.new(.{@floatCast(canvas_start.element(0)), @as(f32, @floatCast(canvas_end.element(1))) + imgui.getStyle().FramePadding.x}));
}
