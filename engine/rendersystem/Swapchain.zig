const vk = @import("vulkan");
const std = @import("std");
const VulkanContext = @import("./VulkanContext.zig");

const utils = @import("./utils.zig");

const SwapchainError = error {
    InvalidSurfaceDimensions,
};

const max_image_count = 3;

handle: vk.SwapchainKHR,
images: std.BoundedArray(vk.Image, max_image_count),
image_index: u32,
extent: vk.Extent2D,

const Self = @This();

pub fn create(vc: *const VulkanContext, ideal_extent: vk.Extent2D) !Self {
    return try createFromOld(vc, ideal_extent, .null_handle);
}

fn createFromOld(vc: *const VulkanContext, ideal_extent: vk.Extent2D, old_handle: vk.SwapchainKHR) !Self {
    var real_extent = ideal_extent;
    const settings = try SwapSettings.find(vc, &real_extent);

    const queue_family_indices = [_]u32{ vc.physical_device.queue_family_index };

    const handle = try vc.device.createSwapchainKHR(&.{
        .surface = vc.surface,
        .min_image_count = settings.image_count,
        .image_format = settings.format.format,
        .image_color_space = settings.format.color_space,
        .image_extent = real_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = settings.image_sharing_mode,
        .queue_family_index_count = @intCast(u32, queue_family_indices.len),
        .p_queue_family_indices = &queue_family_indices,
        .pre_transform = settings.pre_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = settings.present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = old_handle,
    }, null);
    errdefer vc.device.destroySwapchainKHR(handle, null);

    const images = try utils.getVkSliceBounded(max_image_count, @TypeOf(vc.device).getSwapchainImagesKHR, .{ vc.device, handle });

    return Self {
        .handle = handle,
        .images = images,
        .image_index = undefined, // this is odd, is it the best?
        .extent = real_extent,
    };
}

pub fn currentImage(self: *const Self) vk.Image {
    return self.images.get(self.image_index);
}

// assumes old handle destruction is handled
pub fn recreate(self: *Self, vc: *const VulkanContext, extent: vk.Extent2D) !void {
    self.* = try createFromOld(vc, extent, self.handle);
}

pub fn acquireNextImage(self: *Self, vc: *const VulkanContext, semaphore: vk.Semaphore) !vk.Result {
    const result = try vc.device.acquireNextImage2KHR(&.{
        .swapchain = self.handle,
        .timeout = std.math.maxInt(u64),
        .semaphore = semaphore,
        .fence = .null_handle,
        .device_mask = 1,
    });
    self.image_index = result.image_index;
    return result.result;
}

pub fn present(self: *const Self, vc: *const VulkanContext, queue: vk.Queue, semaphore: vk.Semaphore) !vk.Result {
    return try vc.device.queuePresentKHR(queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &semaphore),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast([*]const vk.SwapchainKHR, &self.handle),
        .p_image_indices = @ptrCast([*]const u32, &self.image_index),
        .p_results = null,
    });
}

pub fn destroy(self: *const Self, vc: *const VulkanContext) void {
    vc.device.destroySwapchainKHR(self.handle, null);
}

const SwapSettings = struct {
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    image_count: u32,
    image_sharing_mode: vk.SharingMode,
    pre_transform: vk.SurfaceTransformFlagsKHR,

    // updates mutable extent
    pub fn find(vc: *const VulkanContext, extent: *vk.Extent2D) !SwapSettings {
        const caps = try vc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(vc.physical_device.handle, vc.surface);
        try updateExtent(extent, caps);

        return SwapSettings {
            .format = try findFormat(vc),
            .present_mode = try findPresentMode(vc),
            .image_count = if (caps.max_image_count == 0) caps.min_image_count + 1 else std.math.min(caps.min_image_count + 1, caps.max_image_count),
            .image_sharing_mode = .exclusive,
            .pre_transform = caps.current_transform,
        };
    }

    pub fn findPresentMode(vc: *const VulkanContext) !vk.PresentModeKHR {
        const ideal = vk.PresentModeKHR.mailbox_khr;

        const present_modes = (try utils.getVkSliceBounded(8, @TypeOf(vc.instance).getPhysicalDeviceSurfacePresentModesKHR, .{ vc.instance, vc.physical_device.handle, vc.surface })).slice();

        for (present_modes) |present_mode| {
            if (std.meta.eql(present_mode, ideal)) {
                return ideal;
            }
        }

        return present_modes[0];
    }

    pub fn findFormat(vc: *const VulkanContext) !vk.SurfaceFormatKHR {

        const ideal = vk.SurfaceFormatKHR {
            .format = .b8g8r8a8_srgb,
            .color_space = .srgb_nonlinear_khr,
        };

        const formats = (try utils.getVkSliceBounded(8, @TypeOf(vc.instance).getPhysicalDeviceSurfaceFormatsKHR, .{ vc.instance, vc.physical_device.handle, vc.surface })).slice();

        for (formats) |format| {
            if (std.meta.eql(format, ideal)) {
                return ideal;
            }
        }

        return formats[0];
    }

    pub fn updateExtent(extent: *vk.Extent2D, caps: vk.SurfaceCapabilitiesKHR) !void {
        if (caps.current_extent.width == std.math.maxInt(u32)) {
            extent.* = vk.Extent2D {
                .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
                .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
            };
        } else {
            extent.* = caps.current_extent;
        }
        if (extent.*.height == 0 and extent.*.width == 0) {
            return SwapchainError.InvalidSurfaceDimensions;
        } 
    }
};
