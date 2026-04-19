const std = @import("std");
const vk = @import("vulkan");

const engine = @import("engine");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const Pipeline = engine.hrtsystem.pipeline.Render;
const Scene = engine.hrtsystem.Scene;

const vk_helpers = core.vk_helpers;
const exr = engine.fileformats.exr;

const vector = engine.vector;
const F32x3 = vector.Vec3(f32);
const Mat4x3 = vector.Mat4x3(f32);

const Config = struct {
    in_filepath: []const u8, // must be gltf/glb
    out_filepath: []const u8, // must be exr
    skybox_filepath: []const u8, // must be exr
    spp: u32,
    extent: vk.Extent2D,

    fn fromCli(allocator: std.mem.Allocator, args: std.process.Args) !Config {
        var args_iter = try args.iterateAllocator(allocator);
        defer args_iter.deinit();

        _ = args_iter.next().?;

        const in_filepath = args_iter.next().?;
        if (!std.mem.eql(u8, std.fs.path.extension(in_filepath), ".glb") and !std.mem.eql(u8, std.fs.path.extension(in_filepath), ".gltf")) return error.OnlySupportsGltfInput;

        const skybox_filepath = args_iter.next().?;
        if (!std.mem.eql(u8, std.fs.path.extension(skybox_filepath), ".exr")) return error.OnlySupportsExrSkybox;

        const out_filepath = args_iter.next().?;
        if (!std.mem.eql(u8, std.fs.path.extension(out_filepath), ".exr")) return error.OnlySupportsExrOutput;

        const spp = try std.fmt.parseInt(u32, args_iter.next().?, 10);

        return Config {
            .in_filepath = try allocator.dupe(u8, in_filepath),
            .out_filepath = try allocator.dupe(u8, out_filepath),
            .skybox_filepath = try allocator.dupe(u8, skybox_filepath),
            .spp = spp,
            .extent = vk.Extent2D { .width = 1280, .height = 720 }, // TODO: cli
        };
    }

    fn destroy(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.in_filepath);
        allocator.free(self.out_filepath);
        allocator.free(self.skybox_filepath);
    }
};

const IntervalLogger = struct {
    last_time: std.Io.Timestamp,

    fn start(io: std.Io) IntervalLogger {
        return IntervalLogger {
            .last_time = std.Io.Timestamp.now(io, .real),
        };
    }

    fn log(self: *IntervalLogger, io: std.Io, state: []const u8) !void {
        const new_time = std.Io.Timestamp.now(io, .real);
        const elapsed: u96 = @intCast(self.last_time.durationTo(new_time).toNanoseconds());
        const ms = elapsed / std.time.ns_per_ms;
        const s = ms / std.time.ms_per_s;
        const ms_remainder = ms % std.time.ms_per_s;

        var out_stream = std.Io.File.stdout().writer(io, &.{});
        const writer = &out_stream.interface;
        try writer.print("{}.{:0>3} seconds to {s}\n", .{ s, ms_remainder, state });
        try writer.flush();

        self.last_time = new_time;
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = engine.Allocator.init();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io = std.Io.Threaded.init(allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer io.deinit();

    const context = try VulkanContext.create(allocator, "offline", engine.hrtsystem.vulkan_requirements);
    defer context.destroy(allocator);

    run(allocator, io.io(), init.args, context) catch |err| {
        if (err == error.DeviceLost) try context.handleDeviceLost(allocator);
        return err;
    };
}

fn run(allocator: std.mem.Allocator, io: std.Io, args: std.process.Args, context: VulkanContext) !void {
    var logger = IntervalLogger.start(io);

    const config = try Config.fromCli(allocator, args);
    defer config.destroy(allocator);

    var encoder = try Encoder.create(&context, "main");
    defer encoder.destroy(&context);

    try logger.log(io, "set up initial state");

    try encoder.begin();
    var scene = try Scene.fromGltfExr(&context, allocator, io, &encoder, config.in_filepath, config.skybox_filepath, config.extent, engine.color.Chromaticities.bt709);
    defer scene.destroy(&context, allocator);
    try encoder.submitAndIdleUntilDone(&context);

    try logger.log(io, "load world");

    var pipeline = try Pipeline.create(&context, .{}, .{ scene.background.equal_area_sampler }, .{ scene.world.materials.textures.descriptor_layout.handle, scene.world.constant_spectra.descriptor_layout.handle });
    defer pipeline.destroy(&context);

    try logger.log(io, "create pipeline");

    const output_buffer = try core.mem.DownloadBuffer([4]f32).create(&context, scene.camera.sensors.items[0].extent.width * scene.camera.sensors.items[0].extent.height, "output");
    defer output_buffer.destroy(&context);

    // actual ray tracing
    {
        try encoder.begin();

        // prepare our stuff
        encoder.barrier(&[_]Encoder.ImageBarrier {
            Encoder.ImageBarrier {
                .dst_stage_mask = .{ .compute_shader_bit = true },
                .dst_access_mask = .{ .shader_storage_write_bit = true },
                .old_layout = .undefined,
                .new_layout = .general,
                .image = scene.camera.sensors.items[0].image.handle,
            }
        }, &.{});

        // bind our stuff
        pipeline.recordBindPipeline(encoder.buffer);
        pipeline.recordBindAdditionalDescriptorSets(encoder.buffer, .{ scene.world.materials.textures.descriptor_set, scene.world.constant_spectra.descriptor_set });
        pipeline.recordPushDescriptors(encoder.buffer, scene.pushDescriptors(0, 0, 0));

        for (0..config.spp) |sample_count| {
            // push our stuff
            pipeline.recordPushConstants(encoder.buffer, scene.pushConstants(0, 0, 0, scene.camera.sensors.items[0].sample_count));

            // trace our stuff
            pipeline.recordDispatchThreads2D(encoder.buffer, scene.camera.sensors.items[0].extent);

            // if not last invocation, need barrier cuz we write to images
            if (sample_count != config.spp - 1) {
                encoder.barrier(&[_]Encoder.ImageBarrier {
                    Encoder.ImageBarrier {
                        .src_stage_mask = .{ .compute_shader_bit = true },
                        .src_access_mask = if (sample_count == 0) .{ .shader_storage_write_bit = true } else .{ .shader_storage_write_bit = true, .shader_storage_read_bit = true },
                        .dst_stage_mask = .{ .compute_shader_bit = true },
                        .dst_access_mask = .{ .shader_storage_write_bit = true, .shader_storage_read_bit = true },
                        .image = scene.camera.sensors.items[0].image.handle,
                    },
                }, &.{});
            }
            scene.camera.sensors.items[0].sample_count += 1;
        }

        // copy our stuff
        encoder.barrier(&[_]Encoder.ImageBarrier {
            Encoder.ImageBarrier {
                .src_stage_mask = .{ .compute_shader_bit = true },
                .src_access_mask = .{ .shader_storage_write_bit = true, .shader_storage_read_bit = true },
                .dst_stage_mask = .{ .copy_bit = true },
                .dst_access_mask = .{ .transfer_read_bit = true },
                .image = scene.camera.sensors.items[0].image.handle,
            }
        }, &.{});

        // copy rendered image to host-visible staging buffer
        encoder.copyImageToBuffer(scene.camera.sensors.items[0].image.handle, scene.camera.sensors.items[0].extent, output_buffer.handle);

        try encoder.submitAndIdleUntilDone(&context);
    }

    try logger.log(io, "render");

    // now done with GPU stuff/all rendering; can write from output buffer to exr
    try exr.helpers.Rgba2D.save(exr.helpers.Rgba2D { .ptr = output_buffer.mapped, .extent = scene.camera.sensors.items[0].extent }, allocator, io, config.out_filepath);

    try logger.log(io, "write exr");
}
