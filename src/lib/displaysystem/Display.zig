const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const DestructionQueue = core.DestructionQueue;
const Encoder = core.Encoder;
const vk_helpers = core.vk_helpers;

const Window = engine.Window;

const Swapchain = engine.displaysystem.Swapchain;

// DOUBLE BUFFER STRATEGY
// This uses the strategy that I think is most decent while being the simplest to implement.
//
// We have two "frames in flight", frame A and frame B, which cycle.
// While frame A is being processed by the GPU and displayed, we are recording frame B.
// Essentially this means that while frame A is doing GPU work, frame B is doing CPU work.
//
// This means that for e.g., vertex animation, we don't need to keep two separate GPU vertex buffers,
// as just one GPU task is being done at a time. We just queue the update in command buffer B via a
// buffer copy or update command, which doesn't affect the work of command buffer A.
//
// The catch here is that we must keep two copies of non-static GPU-accesible host data, as when we are updating
// the data for command buffer B, command buffer A could be using that data in another operation.
// In many cases, this can be avoided by using vkCmdUpdateBuffer rather than a transfer operation.
pub const frames_in_flight = 2;

const Self = @This();

frames: [frames_in_flight]Frame,
frame_index: u8,

swapchain_image_index: u32,
swapchain: Swapchain,
surface: vk.SurfaceKHR,

pub fn create(vc: *const VulkanContext, window: Window, supports_swapchain_color_spaces: bool, allocator: std.mem.Allocator) !Self {
    const surface = try window.createSurface(vc.instance.handle);
    errdefer vc.instance.destroySurfaceKHR(surface, null);

    const formats = if (supports_swapchain_color_spaces) &(swapchain_color_space_formats ++ base_formats) else &base_formats;
    var swapchain = try Swapchain.create(vc, window.getExtent(), formats, surface, allocator);
    errdefer swapchain.destroy(vc, allocator);

    var frames: [frames_in_flight]Frame = undefined;
    inline for (&frames, 0..) |*frame, i| {
        frame.* = try Frame.create(vc, std.fmt.comptimePrint("frame {}", .{i}), i != 0);
    }

    return Self {
        .swapchain = swapchain,
        .surface = surface,
        .frames = frames,
        .frame_index = 0,
        .swapchain_image_index = undefined, // hmm
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.swapchain.destroy(vc, allocator);
    vc.instance.destroySurfaceKHR(self.surface, null);
    inline for (&self.frames) |*frame| {
        frame.destroy(vc);
    }
}

// only support HDR on Linux right now because on Linux it's just this easy
// doing it properly on Windows requires querying information from the OS
const swapchain_color_space_formats = if (@import("builtin").os.tag == .linux) [_]Swapchain.SurfaceFormat {
    // it's unclear whether I should prefer the 16-bit float format over the 10-bit integer format.
    // theoretically most HDR displays should be 12-bit, not just 10-bit,
    // so we would be losing something by using 10 bits only.
    .{
        .format = .r16g16b16a16_sfloat,
        .primaries = .bt2020,
        .transfer_function = .st2084_pq,
    },
    .{
        .format = .a2r10g10b10_unorm_pack32,
        .primaries = .bt2020,
        .transfer_function = .st2084_pq,
    },
} else [_]Swapchain.SurfaceFormat {};

const base_formats = [_]Swapchain.SurfaceFormat {
    .{
        .format = .b8g8r8a8_unorm,
        .primaries = .bt709,
        .transfer_function = .srgb,
    },
    .{
        .format = .r8g8b8a8_unorm,
        .primaries = .bt709,
        .transfer_function = .srgb,
    },
};

pub fn startFrame(self: *Self, vc: *const VulkanContext) !*Encoder {
    const frame = &self.frames[self.frame_index];

    self.swapchain_image_index = try self.swapchain.acquireNextImage(vc, frame.image_acquired);

    try frame.encoder.begin();

    return &frame.encoder;
}

pub fn currentImage(self: *const Self) Swapchain.Image {
    return self.swapchain.images[self.swapchain_image_index];
}

// returns old swapchain
pub fn recreate(self: *Self, vc: *const VulkanContext, window: Window, supports_swapchain_color_spaces: bool, allocator: std.mem.Allocator) !Swapchain {
    const old_swapchain = self.swapchain;
    const formats = if (supports_swapchain_color_spaces) &(swapchain_color_space_formats ++ base_formats) else &base_formats;
    self.swapchain = try Swapchain.createFromOld(vc, window.getExtent(), formats, self.surface, allocator, old_swapchain);
    return old_swapchain;
}

pub fn endFrame(self: *Self, vc: *const VulkanContext) !vk.Result {
    const result = blk: {
        const frame = self.frames[self.frame_index];

        try frame.encoder.submit(vc.queue, .{
            .wait_semaphore_infos = &[_]vk.SemaphoreSubmitInfoKHR {
                .{
                    .semaphore = frame.image_acquired,
                    .value = 0,
                    .stage_mask = .{ .color_attachment_output_bit = true },
                    .device_index = 0,
                }
            },
            .signal_semaphore_infos = &[_]vk.SemaphoreSubmitInfoKHR {
                .{
                    .semaphore = frame.command_completed,
                    .value = 0,
                    .stage_mask =  .{ .color_attachment_output_bit = true },
                    .device_index = 0,
                }
            },
            .fence = frame.fence,
        });

        // TODO: the synchronization here is not sufficient, as the semaphore
        // may still be in use by the previous usage of this swapchain image.
        // fix this with VK_EXT_swapchain_maintenance1 once it becomes
        // more widely supported.
        break :blk self.swapchain.present(vc, frame.command_completed, self.swapchain_image_index);
    };

    self.frame_index = (self.frame_index + 1) % frames_in_flight;

    // wait for next frame to ensure CPU is not too far ahead of GPU
    var next_frame = &self.frames[self.frame_index];
    _ = try vc.device.waitForFences(1, (&next_frame.fence)[0..1], vk.TRUE, std.math.maxInt(u64));

    // reset resources associated with next frame so it is ready for use on next startFrame
    try next_frame.reset(vc);

    return result;
}

const Frame = struct {
    image_acquired: vk.Semaphore,
    command_completed: vk.Semaphore,
    fence: vk.Fence,

    encoder: Encoder,

    fn create(vc: *const VulkanContext, name: [*:0]const u8, fence_initially_signaled: bool) !Frame {
        const image_acquired = try vc.device.createSemaphore(&.{}, null);
        errdefer vc.device.destroySemaphore(image_acquired, null);

        const command_completed = try vc.device.createSemaphore(&.{}, null);
        errdefer vc.device.destroySemaphore(command_completed, null);

        const fence = try vc.device.createFence(&.{
            .flags = if (fence_initially_signaled) .{ .signaled_bit = true } else .{},
        }, null);

        var encoder = try Encoder.create(vc, name);
        errdefer encoder.destroy(vc);

        return Frame {
            .image_acquired = image_acquired,
            .command_completed = command_completed,
            .fence = fence,

            .encoder = encoder,
        };
    }

    // frame must not be in use
    fn reset(self: *Frame, vc: *const VulkanContext) !void {
        try vc.device.resetFences(1, (&self.fence)[0..1]);
        try self.encoder.clearResources(vc);
    }

    fn destroy(self: *Frame, vc: *const VulkanContext) void {
        vc.device.destroySemaphore(self.image_acquired, null);
        vc.device.destroySemaphore(self.command_completed, null);
        vc.device.destroyFence(self.fence, null);
        self.encoder.destroy(vc);
    }
};
