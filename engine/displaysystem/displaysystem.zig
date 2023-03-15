pub const Display = @import("./display.zig").Display;
pub const Swapchain = @import("./Swapchain.zig");
const metrics = @import("build_options").vk_metrics;

const vk = @import("vulkan");
pub const required_instance_functions = vk.InstanceCommandFlags {
    .destroySurfaceKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
};
const base_required_device_functions = vk.DeviceCommandFlags {
    .getSwapchainImagesKHR = true,
    .createSwapchainKHR = true,
    .acquireNextImage2KHR = true,
    .queuePresentKHR = true,
    .destroySwapchainKHR = true,
};

const metrics_device_functions = vk.DeviceCommandFlags {
    .cmdWriteTimestamp2 = true,
};

pub const required_device_functions = if (metrics) base_required_device_functions.merge(metrics_device_functions) else base_required_device_functions;