pub const Display = @import("./display.zig").Display;

const vk = @import("vulkan");
pub const required_instance_functions = vk.InstanceCommandFlags {
    .destroySurfaceKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
};
pub const required_device_functions = vk.DeviceCommandFlags {
    .getSwapchainImagesKHR = true,
    .createSwapchainKHR = true,
    .acquireNextImage2KHR = true,
    .queuePresentKHR = true,
    .destroySwapchainKHR = true,
};

pub const measure_perf_device_functions = vk.DeviceCommandFlags {
    .cmdWriteTimestamp2 = true,
};
