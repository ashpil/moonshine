const vk = @import("vulkan");
const std = @import("std");
const c = @import("./c.zig");
const VulkanContext = @import("./vulkan_context.zig");

const SwapchainError = error {
    InvalidSurfaceDimensions,
};

handle: vk.SwapchainKHR,
images: []SwapImage,

image_acquired_semaphore: vk.Semaphore,
render_finished_semaphore: vk.Semaphore,

const Self = @This();

pub fn create(vc: *const VulkanContext, allocator: *std.mem.Allocator, extent: vk.Extent2D) !Self {

    const settings = try SwapSettings.find(vc, allocator, extent);

    const queue_family_indices = if (settings.image_sharing_mode == .exclusive)
        (&[_]u32{ vc.physical_device.queue_families.compute })
    else
        (&[_]u32{ vc.physical_device.queue_families.compute, vc.physical_device.queue_families.present });

    const handle = try vc.device.createSwapchainKHR(.{
        .flags = .{},
        .surface = vc.surface,
        .min_image_count = settings.image_count,
        .image_format = settings.format.format,
        .image_color_space = settings.format.color_space,
        .image_extent = settings.extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = settings.image_sharing_mode,
        .queue_family_index_count = @intCast(u32, queue_family_indices.len),
        .p_queue_family_indices = queue_family_indices.ptr,
        .pre_transform = settings.pre_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = settings.present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = .null_handle,
    }, null);
    errdefer vc.device.destroySwapchainKHR(handle, null);

    var image_count: u32 = 0;
    _ = try vc.device.getSwapchainImagesKHR(handle, &image_count, null);
    var images = try allocator.alloc(vk.Image, image_count);
    defer allocator.free(images);
    _ = try vc.device.getSwapchainImagesKHR(handle, &image_count, images.ptr);
    
    var swap_images = try allocator.alloc(SwapImage, image_count);
    errdefer allocator.free(swap_images);
    for (images) |image, i| {
        swap_images[i] = try SwapImage.create(vc, image, settings.format.format);
    }

    const image_acquired_semaphore = try vc.device.createSemaphore(.{
        .flags = .{},
    }, null);

    const render_finished_semaphore = try vc.device.createSemaphore(.{
        .flags = .{},
    }, null);

    return Self {
        .handle = handle,
        .images = swap_images,

        .image_acquired_semaphore = image_acquired_semaphore,
        .render_finished_semaphore = render_finished_semaphore,
    };
}

// TODO: GPU-GPU sync done, do GPU-CPU with fences prob seems to be the way?
// TODO: handle suboptimal swapchain
pub fn present(self: *Self, vc: *const VulkanContext) !void {
    const image_index = (try vc.device.acquireNextImageKHR(self.handle, std.math.maxInt(u64), self.image_acquired_semaphore, .null_handle)).image_index;
    _ = image_index;

    //try vc.device.queueSubmit(queue, 1, &[_]vk.SubmitInfo { .{
    //    .wait_semaphore_count = 1,
    //    .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &self.image_acquired_semaphore),
    //    .p_wait_dst_stage_mask = &[_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }},
    //    .command_buffer_count = 1,
    //    .p_command_buffers = command_buffers[image_index],
    //    .signal_semaphore_count = 1,
    //    .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &self.render_finished_semaphore),
    //}}, .null_handle);

    //_ = try vc.device.queuePresentKHR(queue, .{
    //    .wait_semaphore_count = 1,
    //    .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &self.render_finished_semaphore),
    //    .swapchain_count = 1,
    //    .p_swapchains = @ptrCast([*]const vk.SwapchainKHR, &self.handle),
    //    .p_image_indices = @ptrCast([*]const u32, &image_index),
    //    .p_results = null,
    //});
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: *std.mem.Allocator) void {
    vc.device.destroySemaphore(self.image_acquired_semaphore, null);
    vc.device.destroySemaphore(self.render_finished_semaphore, null);
    for (self.images) |image| {
        image.destroy(vc);
    }
    allocator.free(self.images);
    vc.device.destroySwapchainKHR(self.handle, null);
}

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,

    fn create(vc: *const VulkanContext, image: vk.Image, format: vk.Format) !SwapImage {

        const view = try vc.device.createImageView(.{
            .flags = .{},
            .image = image,
            .view_type = vk.ImageViewType.@"2d",
            .format = format,
            .components = .{
                .r = .one,
                .g = .one,
                .b = .one,
                .a = .one,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        return SwapImage {
            .image = image,
            .view = view,
        };
    }

    fn destroy(self: SwapImage, vc: *const VulkanContext) void {
        vc.device.destroyImageView(self.view, null);
    }
};

const SwapSettings = struct {
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    image_count: u32,
    image_sharing_mode: vk.SharingMode,
    pre_transform: vk.SurfaceTransformFlagsKHR,

    pub fn find(vc: *const VulkanContext, allocator: *std.mem.Allocator, extent: vk.Extent2D) !SwapSettings {
        const caps = try vc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(vc.physical_device.handle, vc.surface);

        return SwapSettings {
            .format = try findFormat(vc, allocator),
            .present_mode = try findPresentMode(vc, allocator),
            .extent = try getExtent(extent, caps),
            .image_count = if (caps.max_image_count == 0) caps.min_image_count + 1 else std.math.min(caps.min_image_count + 1, caps.max_image_count),
            .image_sharing_mode = vc.physical_device.queue_families.sharingMode(),
            .pre_transform = caps.current_transform,
        };
    }

    pub fn findPresentMode(vc: *const VulkanContext, allocator: *std.mem.Allocator) !vk.PresentModeKHR {

        const ideal = vk.PresentModeKHR.mailbox_khr;

        var present_mode_count: u32 = 0;
        _ = try vc.instance.getPhysicalDeviceSurfacePresentModesKHR(vc.physical_device.handle, vc.surface, &present_mode_count, null);

        const present_modes = try allocator.alloc(vk.PresentModeKHR, present_mode_count);
        defer allocator.free(present_modes);
        _ = try vc.instance.getPhysicalDeviceSurfacePresentModesKHR(vc.physical_device.handle, vc.surface, &present_mode_count, present_modes.ptr);

        for (present_modes) |present_mode| {
            if (std.meta.eql(present_mode, ideal)) {
                return ideal;
            }
        }

        return present_modes[0];
    }

    pub fn findFormat(vc: *const VulkanContext, allocator: *std.mem.Allocator) !vk.SurfaceFormatKHR {

        const ideal = vk.SurfaceFormatKHR {
            .format = .b8g8r8a8_srgb,
            .color_space = .srgb_nonlinear_khr,
        };

        var format_count: u32 = 0;
        _ = try vc.instance.getPhysicalDeviceSurfaceFormatsKHR(vc.physical_device.handle, vc.surface, &format_count, null);

        const formats = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
        defer allocator.free(formats);
        _ = try vc.instance.getPhysicalDeviceSurfaceFormatsKHR(vc.physical_device.handle, vc.surface, &format_count, formats.ptr);

        for (formats) |format| {
            if (std.meta.eql(format, ideal)) {
                return ideal;
            }
        }

        return formats[0];
    }

    pub fn getExtent(extent: vk.Extent2D, caps: vk.SurfaceCapabilitiesKHR) !vk.Extent2D {
        var result = caps.current_extent;
        if (caps.current_extent.width == std.math.maxInt(u32)) {
            result = vk.Extent2D {
                .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
                .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
            };
        }
        if (result.height == 0 and result.width == 0) return SwapchainError.InvalidSurfaceDimensions;
        return result;
    }
};
