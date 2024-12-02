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
const Camera = hrtsystem.Camera;
const Accel = hrtsystem.Accel;
const MaterialManager = hrtsystem.MaterialManager;
const Scene = hrtsystem.Scene;
const PathTracingPipeline = hrtsystem.pipeline.PathTracing;
const DirectLightingPipeline = hrtsystem.pipeline.DirectLighting;
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

// I'm certain at some point I'll look back on this and think that there's absolutely no reason this required this level of
// metaprogramming. in fact, I'm already sort of doing it now
const Integrator = struct {
    pub fn IntegratorWithOptions(Pipeline: type) type {
        return struct {
            pipeline: Pipeline,
            options: Pipeline.SpecConstants,
        };
    }

    const Variants = struct {
        path_tracing: IntegratorWithOptions(PathTracingPipeline),
        direct_lighting: IntegratorWithOptions(DirectLightingPipeline),
    };

    const Type = blk: {
        var fields: [@typeInfo(Variants).@"struct".fields.len]std.builtin.Type.EnumField = undefined;
        for (@typeInfo(Variants).@"struct".fields, &fields, 0..) |struct_field, *enum_field, i| {
            enum_field.* = std.builtin.Type.EnumField {
                .name = struct_field.name,
                .value = i,
            };
        }
        break :blk @Type(std.builtin.Type {
            .@"enum" = std.builtin.Type.Enum {
                .tag_type = usize,
                .fields = &fields,
                .decls = &.{},
                .is_exhaustive = true,
            }
        });
    };

    variants: Variants,
    active: Type,

    pub fn create(vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder, scene: Scene) !Integrator {
        var integrator: Integrator = undefined;
        integrator.active = .path_tracing;

        inline for (@typeInfo(Variants).@"struct".fields) |field| {
            @field(integrator.variants, field.name).pipeline = try @typeInfo(field.type).@"struct".fields[0].type.create(vc, allocator, encoder, .{ scene.world.materials.textures.descriptor_layout.handle, scene.world.constant_specta.descriptor_layout.handle }, .{}, .{ scene.background.sampler });
            @field(integrator.variants, field.name).options = .{};
        }

        return integrator;
    }

    // recreates all so that a change in a shader doesn't get missed
    pub fn recreate(self: *Integrator, vc: *const VulkanContext, allocator: std.mem.Allocator, encoder: *Encoder) std.BoundedArray(anyerror!vk.Pipeline, @typeInfo(Variants).@"struct".fields.len) {
        var out = std.BoundedArray(anyerror!vk.Pipeline, @typeInfo(Variants).@"struct".fields.len) {};
        inline for (@typeInfo(Variants).@"struct".fields) |field| {
            out.append(@field(self.variants, field.name).pipeline.recreate(vc, allocator, encoder, @field(self.variants, field.name).options)) catch unreachable;
        }
        return out;
    }

    pub fn integrate(self: Integrator, scene: Scene, encoder: *Encoder, active_sensor: u32) void {
        inline for (@typeInfo(Variants).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, @tagName(self.active))) {
                const integrator = @field(self.variants, field.name).pipeline;

                // bind some stuff
                integrator.recordBindPipeline(encoder.buffer);
                integrator.recordBindAdditionalDescriptorSets(encoder.buffer, .{ scene.world.materials.textures.descriptor_set, scene.world.constant_specta.descriptor_set });

                // push some stuff
                integrator.recordPushDescriptors(encoder.buffer, scene.pushDescriptors(active_sensor, 0));
                integrator.recordPushConstants(encoder.buffer, .{ .lens = scene.camera.lenses.items[0], .aspect_ratio = scene.camera.sensors.items[active_sensor].aspectRatio(), .sample_count = scene.camera.sensors.items[active_sensor].sample_count });

                // trace some stuff
                integrator.recordTraceRays(encoder.buffer, scene.camera.sensors.items[active_sensor].extent);
                break;
            }
        } else unreachable;
    }

    pub fn exposeToImgui(self: *Integrator) void {
        inline for (@typeInfo(Variants).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, @tagName(self.active))) {
                inline for (@typeInfo(@TypeOf(@field(self.variants, field.name).options)).@"struct".fields) |option| {
                    _ = switch (option.type) {
                        u32 => imgui.dragScalar(u32, option.name, &@field(@field(self.variants, field.name).options, option.name), 1.0, 0, std.math.maxInt(u32)),
                        else => unreachable, // TODO
                    };
                }

                break;
            }
        } else unreachable;
    }

    pub fn destroy(self: *Integrator, vc: *const VulkanContext) void {
        inline for (@typeInfo(Variants).@"struct".fields) |field| {
            @field(self.variants, field.name).pipeline.destroy(vc);
        }
    }
};

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

    var integrator = try Integrator.create(&context, allocator, &encoder, scene);
    defer integrator.destroy(&context);

    var gui = try Platform.create(&context, display.swapchain, window, window_extent, &encoder);
    defer gui.destroy(&context);

    try encoder.submitAndIdleUntilDone(&context);

    std.log.info("Created pipelines!", .{});

    // random state we need for gui
    var active_sensor: u32 = 0;
    var max_sample_count: u32 = 0; // unlimited
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
            var changed = imgui.sliderAngle("Vertical FOV", &scene.camera.lenses.items[0].vfov, 1, 179);
            changed = imgui.dragScalar(f32, "Focus distance", &scene.camera.lenses.items[0].focus_distance, 0.1, -std.math.inf(f32), std.math.inf(f32)) or changed;
            changed = imgui.dragScalar(f32, "Aperture size", &scene.camera.lenses.items[0].aperture, 0.01, 0.0, std.math.inf(f32)) or changed;
            changed = imgui.dragVector(F32x3, "Origin", &scene.camera.lenses.items[0].origin, 0.1, -std.math.inf(f32), std.math.inf(f32)) or changed;
            changed = imgui.dragVector(F32x3, "Forward", &scene.camera.lenses.items[0].forward, 0.1, -1.0, 1.0) or changed;
            changed = imgui.dragVector(F32x3, "Up", &scene.camera.lenses.items[0].up, 0.1, -1.0, 1.0) or changed;
            if (changed) {
                scene.camera.lenses.items[0].forward = scene.camera.lenses.items[0].forward.unit();
                scene.camera.lenses.items[0].up = scene.camera.lenses.items[0].up.unit();
                scene.camera.sensors.items[active_sensor].clear();
            }
            imgui.popItemWidth();
        }
        if (imgui.collapsingHeader("Integrator")) {
            imgui.pushItemWidth(imgui.getFontSize() * -14.2);
            if (imgui.combo(Integrator.Type, "Type", &integrator.active)) {
                scene.camera.sensors.items[active_sensor].clear();
            }
            integrator.exposeToImgui();
            const last_rebuild_failed = rebuild_error;
            if (last_rebuild_failed) imgui.pushStyleColor(.text, F32x4.new(1.0, 0.0, 0.0, 1));
            if (imgui.button(rebuild_label, imgui.Vec2{ .x = imgui.getContentRegionAvail().x, .y = 0.0 })) {
                const start = try std.time.Instant.now();
                rebuild_error = false;
                try encoder.begin();
                for (integrator.recreate(&context, allocator, &encoder).slice()) |result| {
                    if (result) |old_pipeline| {
                        try frame_encoder.attachResource(old_pipeline);
                        scene.camera.sensors.items[active_sensor].clear();
                    } else |err| if (err == error.ShaderCompileFail) {
                        rebuild_error = true;
                    } else return err;
                }
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
        imgui.setNextWindowPos(@as(f32, @floatFromInt(@max(display.swapchain.extent.width, 50) - 50)) - 250, 50);
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
                const instance = try sync_copier.copyBufferItem(&context, vk.AccelerationStructureInstanceKHR, scene.world.accel.instances_device.handle, object.instance_index);
                const accel_geometry_index = instance.instance_custom_index_and_mask.instance_custom_index + object.geometry_index;
                var geometry = try sync_copier.copyBufferItem(&context, Accel.Geometry, scene.world.accel.geometries.handle, accel_geometry_index);
                const material = try sync_copier.copyBufferItem(&context, MaterialManager.GpuMaterial, scene.world.materials.materials.handle, geometry.material);
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
                try imgui.textFmt("normal: {}", .{material.normal});
                try imgui.textFmt("emissive: {}", .{material.emissive});
                try imgui.textFmt("type: {s}", .{@tagName(material.type)});
                inline for (@typeInfo(MaterialManager.BSDF).@"enum".fields, @typeInfo(MaterialManager.PolymorphicBSDF).@"union".fields) |enum_field, union_field| {
                    const VariantType = union_field.type;
                    if (VariantType != void and enum_field.value == @intFromEnum(material.type)) {
                        const material_idx: u32 = @intCast((material.addr - @field(scene.world.materials.variant_buffers, enum_field.name).addr) / @sizeOf(VariantType));
                        var material_variant = try sync_copier.copyBufferItem(&context, VariantType, @field(scene.world.materials.variant_buffers, enum_field.name).buffer.handle, material_idx);
                        inline for (@typeInfo(VariantType).@"struct".fields) |struct_field| {
                            switch (struct_field.type) {
                                f32 => if (imgui.dragScalar(f32, (struct_field.name[0..struct_field.name.len].* ++ .{ 0 })[0..struct_field.name.len :0], &@field(material_variant, struct_field.name), 0.01, 0, std.math.inf(f32))) {
                                    scene.world.materials.recordUpdateSingleVariant(VariantType, frame_encoder.buffer, material_idx, material_variant);
                                    scene.camera.sensors.items[active_sensor].clear();
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
                    scene.world.accel.recordUpdateSingleTransform(frame_encoder.buffer, object.instance_index, old_transform.with_translation(translation));
                    try scene.world.accel.recordRebuild(frame_encoder.buffer);
                    scene.camera.sensors.items[active_sensor].clear();
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
                const delta = F32x2.new(0.5, 0.5).add(imgui.getMouseDragDelta(.right).div(window_size));
                imgui.resetMouseDragDelta(.right);
                if (!std.meta.eql(delta, F32x2.new(0.5, 0.5))) {
                    const aspect = window_size.x / window_size.y;
                    scene.camera.lenses.items[0].forward = scene.camera.lenses.items[0].directionFromUv(F32x2.new(delta.x, delta.y), aspect);
                    scene.camera.sensors.items[active_sensor].clear();
                }
            } else {
                window.setCursorMode(.normal);
                if (imgui.isMouseClicked(.left)) {
                    current_clicked_object = try object_picker.getClickedObject(&context, scene.world.accel.tlas_handle, imgui.getMousePos().div(window_size), scene.camera.lenses.items[0], scene.camera.sensors.items[active_sensor]);
                    const clicked_pixel = try sync_copier.copyImagePixel(&context, F32x4, scene.camera.sensors.items[active_sensor].image.handle, .transfer_src_optimal, vk.Offset3D { .x = @intFromFloat(imgui.getMousePos().x), .y = @intFromFloat(imgui.getMousePos().y), .z = 0 });
                    current_clicked_color = clicked_pixel.truncate();
                    has_clicked = true;
                }
            }
        }
        if (!imgui.getIO().WantCaptureKeyboard) {
            const old_lens = scene.camera.lenses.items[0];
            const side = old_lens.forward.cross(old_lens.up).unit();
            var new_lens = scene.camera.lenses.items[0];

            const speed = imgui.getIO().DeltaTime;

            if (imgui.isKeyDown(.w)) new_lens.origin = new_lens.origin.add(new_lens.forward.mul_scalar(speed * 30));
            if (imgui.isKeyDown(.s)) new_lens.origin = new_lens.origin.sub(new_lens.forward.mul_scalar(speed * 30));
            if (imgui.isKeyDown(.a)) new_lens.origin = new_lens.origin.add(side.mul_scalar(speed * 30));
            if (imgui.isKeyDown(.d)) new_lens.origin = new_lens.origin.sub(side.mul_scalar(speed * 30));
            if (imgui.isKeyDown(.f) and new_lens.aperture > 0.0) new_lens.aperture -= speed / 10;
            if (imgui.isKeyDown(.r)) new_lens.aperture += speed / 10;
            if (imgui.isKeyDown(.q)) new_lens.focus_distance -= speed * 10;
            if (imgui.isKeyDown(.e)) new_lens.focus_distance += speed * 10;

            if (!std.meta.eql(new_lens, old_lens)) {
                scene.camera.lenses.items[0] = new_lens;
                scene.camera.sensors.items[active_sensor].clear();
            }
        }

        if (max_sample_count != 0 and scene.camera.sensors.items[active_sensor].sample_count > max_sample_count) scene.camera.sensors.items[active_sensor].clear();
        if (max_sample_count == 0 or scene.camera.sensors.items[active_sensor].sample_count < max_sample_count) {
            scene.camera.sensors.items[active_sensor].recordPrepareForCapture(frame_encoder.buffer, .{ .ray_tracing_shader_bit_khr = true }, .{ .blit_bit = true });
            integrator.integrate(scene, frame_encoder, active_sensor);
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