const std = @import("std");
const vk = @import("vulkan");

const engine = @import("../engine.zig");
const color = engine.color;
const VulkanContext = engine.core.VulkanContext;
const Encoder = engine.core.Encoder;
const vk_helpers = engine.core.vk_helpers;

pub const max_image_count = 4;

pub const Image = struct {
    handle: vk.Image,
    view: vk.ImageView,
};

handle: vk.SwapchainKHR = .null_handle,
images: std.BoundedArray(Image, max_image_count) = .{},
extent: vk.Extent2D = .{
    .width = 0,
    .height = 0,
},
// invalid to read these if extent is (0, 0)
primaries: color.Primaries.Named = undefined,
transfer_function: color.TransferFunction = undefined,

const Self = @This();

pub fn create(vc: *const VulkanContext, ideal_extent: vk.Extent2D, surface: vk.SurfaceKHR, transient_allocator: std.mem.Allocator) !Self {
    return try createFromOld(vc, ideal_extent, surface, transient_allocator, .{});
}

pub fn createFromOld(vc: *const VulkanContext, ideal_extent: vk.Extent2D, surface: vk.SurfaceKHR, transient_allocator: std.mem.Allocator, old: Self) !Self {
    const settings = try SwapSettings.find(vc, ideal_extent, surface, transient_allocator);

    const queue_family_indices = [_]u32{ vc.physical_device.queue_family_index };

    const handle = try vc.device.createSwapchainKHR(&.{
        .surface = surface,
        .min_image_count = settings.image_count,
        .image_format = settings.format,
        .image_color_space = getVkColorSpace(settings.primaries, settings.transfer_function).?,
        .image_extent = settings.extent,
        .image_array_layers = 1,
        .image_usage = .{ .storage_bit = true },
        .image_sharing_mode = settings.image_sharing_mode,
        .queue_family_index_count = @as(u32, @intCast(queue_family_indices.len)),
        .p_queue_family_indices = &queue_family_indices,
        .pre_transform = settings.pre_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = settings.present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = old.handle,
    }, null);
    errdefer vc.device.destroySwapchainKHR(handle, null);

    const image_handles = try vk_helpers.getVkSliceBounded(max_image_count, @TypeOf(vc.device).getSwapchainImagesKHR, .{ vc.device, handle });

    var images = std.BoundedArray(Image, max_image_count) {
        .buffer = undefined,
        .len = image_handles.len,
    };

    inline for (&images.buffer, image_handles.buffer, 0..) |*image, image_handle, i| {
        if (i >= images.len) {
            break;
        }
        image.view = try vc.device.createImageView(&vk.ImageViewCreateInfo{
            .image = image_handle,
            .view_type = .@"2d",
            .format = settings.format,
            .components = vk.ComponentMapping{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        image.handle = image_handle;
        try vk_helpers.setDebugName(vc.device, image.view, std.fmt.comptimePrint("swapchain image view {}", .{ i }));
    }


    return Self {
        .handle = handle,
        .images = images,
        .extent = settings.extent,
        .primaries = settings.primaries,
        .transfer_function = settings.transfer_function,
    };
}

pub fn acquireNextImage(self: *Self, vc: *const VulkanContext, semaphore: vk.Semaphore) !u32 {
    // ignore suboptimal here, better to handle on present
    const result = try vc.device.acquireNextImage2KHR(&.{
        .swapchain = self.handle,
        .timeout = std.math.maxInt(u64),
        .semaphore = semaphore,
        .fence = .null_handle,
        .device_mask = 1,
    });
    return result.image_index;
}

pub fn present(self: *const Self, vc: *const VulkanContext, semaphore: vk.Semaphore, image_index: u32) !vk.Result {
    return try vc.queue.presentKHR(&vk.PresentInfoKHR {
        .wait_semaphore_count = 1,
        .p_wait_semaphores = (&semaphore)[0..1],
        .swapchain_count = 1,
        .p_swapchains = (&self.handle)[0..1],
        .p_image_indices = (&image_index)[0..1],
    });
}

pub fn destroy(self: *const Self, vc: *const VulkanContext) void {
    for (self.images.slice()) |image| vc.device.destroyImageView(image.view, null);
    vc.device.destroySwapchainKHR(self.handle, null);
}

pub fn attachToEncoder(self: *const Self, encoder: *Encoder) !void {
    for (self.images.slice()) |image| try encoder.attachResource(image.view);
    try encoder.attachResource(self.handle);
}

const SwapSettings = struct {
    format: vk.Format,
    primaries: color.Primaries.Named,
    transfer_function: color.TransferFunction,
    present_mode: vk.PresentModeKHR,
    image_count: u32,
    image_sharing_mode: vk.SharingMode,
    pre_transform: vk.SurfaceTransformFlagsKHR,
    extent: vk.Extent2D,

    // updates mutable extent
    pub fn find(vc: *const VulkanContext, extent: vk.Extent2D, surface: vk.SurfaceKHR, transient_allocator: std.mem.Allocator) !SwapSettings {
        const caps = try vc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(vc.physical_device.handle, surface);
        const format, const primaries, const transfer_function = try findFormat(vc, surface, transient_allocator);

        return SwapSettings {
            .format = format,
            .primaries = primaries,
            .transfer_function = transfer_function,
            .present_mode = try findPresentMode(vc, surface),
            .image_count = if (caps.max_image_count == 0) caps.min_image_count + 1 else @min(caps.min_image_count + 1, caps.max_image_count),
            .image_sharing_mode = .exclusive,
            .pre_transform = caps.current_transform,
            .extent = try calculateExtent(extent, caps),
        };
    }

    pub fn findPresentMode(vc: *const VulkanContext, surface: vk.SurfaceKHR) !vk.PresentModeKHR {
        const ideal = vk.PresentModeKHR.fifo_khr;

        const present_modes = (try vk_helpers.getVkSliceBounded(8, @TypeOf(vc.instance).getPhysicalDeviceSurfacePresentModesKHR, .{ vc.instance, vc.physical_device.handle, surface })).slice();

        for (present_modes) |present_mode| {
            if (std.meta.eql(present_mode, ideal)) {
                return ideal;
            }
        }

        return present_modes[0];
    }

    pub fn findFormat(vc: *const VulkanContext, surface: vk.SurfaceKHR, transient_allocator: std.mem.Allocator) !std.meta.Tuple(&.{ vk.Format, color.Primaries.Named, color.TransferFunction}) {
        const needed_primaries = color.Primaries.Named.bt709;
        const needed_transfer_function = color.TransferFunction.srgb;
        const needed_vk_color_space = getVkColorSpace(needed_primaries, needed_transfer_function);

        const needed = vk.SurfaceFormatKHR {
            .format = .r8g8b8a8_unorm,
            .color_space = needed_vk_color_space.?,
        };

        const formats = try vc.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(vc.physical_device.handle, surface, transient_allocator);
        defer transient_allocator.free(formats);

        for (formats) |format| {
            if (std.meta.eql(format, needed)) {
                return .{ needed.format, needed_primaries, needed_transfer_function };
            }
        }

        return error.NeededFormatIsUnavailable;
    }

    pub fn calculateExtent(extent: vk.Extent2D, caps: vk.SurfaceCapabilitiesKHR) !vk.Extent2D {
        if (caps.current_extent.width == std.math.maxInt(u32)) {
            return vk.Extent2D {
                .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
                .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
            };
        } else {
            return caps.current_extent;
        }
        if (extent.height == 0 and extent.width == 0) {
            return error.InvalidSurfaceDimensions;
        }
    }
};

fn getVkColorSpace(primaries: color.Primaries.Named, transfer_function: color.TransferFunction) ?vk.ColorSpaceKHR {
    return switch (primaries) {
        .bt709 => switch (transfer_function) {
            .linear => .bt709_linear_ext,
            .extended_linear => .extended_srgb_linear_ext,
            .srgb => .srgb_nonlinear_khr,
            .st2084_pq => null,
        },
        .bt2020 => switch (transfer_function) {
            .linear => .bt2020_linear_ext,
            .extended_linear => null,
            .srgb => null,
            .st2084_pq => .hdr10_st2084_ext,
        },
    };
}

