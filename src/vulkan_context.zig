const c = @import("./c.zig");
const vk = @import("vulkan");
const std = @import("std");
const PhysicalDevice = @import("./vulkan_context/physical_device.zig").PhysicalDevice;
const Swapchain = @import("./vulkan_context/swapchain.zig").Swapchain;

const shared = @import("./vulkan_context/shared.zig");
const Base = shared.Base;
const Instance = shared.Instance;
const Device = shared.Device;
const validate = shared.validate;

pub fn createSurface(instance: Instance, window: *c.GLFWwindow) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    if (c.glfwCreateWindowSurface(instance.handle, window, null, &surface) != vk.Result.success) return shared.VulkanContextError.SurfaceCreateFail;
    return surface;
}

pub const VulkanContext = struct {
    base: Base,
    instance: Instance,
    device: Device,

    physical_device: PhysicalDevice,
    surface: vk.SurfaceKHR,

    debug_messenger: if (validate) vk.DebugUtilsMessengerEXT else void,

    compute_queue: vk.Queue,
    present_queue: vk.Queue,

    swapchain: Swapchain,

    pub fn create(allocator: *std.mem.Allocator, window: *c.GLFWwindow, extent: vk.Extent2D) !VulkanContext {
        const base = try Base.new();

        const instance = try base.createInstance(allocator);
        errdefer instance.destroyInstance(null);

        const debug_messenger = if (validate) try instance.createDebugUtilsMessengerEXT(shared.debug_messenger_create_info, null) else undefined;
        errdefer if (validate) instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);

        const surface = try createSurface(instance, window);
        errdefer instance.destroySurfaceKHR(surface, null);

        const physical_device = try PhysicalDevice.pick(instance, allocator, surface);
        const device = try physical_device.createLogicalDevice(instance);
        errdefer device.destroyDevice(null);

        const compute_queue = device.getDeviceQueue(physical_device.queue_families.compute, 0);
        const present_queue = device.getDeviceQueue(physical_device.queue_families.present, 0);

        const swapchain = try Swapchain.create(instance, device, &physical_device, surface, allocator, extent);

        return VulkanContext {
            .base = base,
            .instance = instance,
            .debug_messenger = debug_messenger,
            .surface = surface,
            .device = device,
            .physical_device = physical_device,
            .compute_queue = compute_queue,
            .present_queue = present_queue,
            .swapchain = swapchain,
        };
    }

    pub fn destroy(self: *VulkanContext, allocator: *std.mem.Allocator) void {
        self.swapchain.destroy(self.device, allocator);
        self.device.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);

        if (validate) self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        self.instance.destroyInstance(null);
    }
};

