pub const Display = @import("./Display.zig");
pub const Swapchain = @import("./Swapchain.zig");

const vk = @import("vulkan");
const VulkanRequirements = @import("../engine.zig").core.VulkanContext.VulkanRequirements;
const Window = @import("../Window.zig");

fn queueFamilyAcceptable(instance: vk.Instance, device: vk.PhysicalDevice, idx: u32) bool {
    return Window.getPhysicalDevicePresentationSupport(instance, device, idx);
}

var swapchain_maintenance_1_features = vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT {
    .swapchain_maintenance_1 = .true,
};

pub const vulkan_requirements = VulkanRequirements {
    .instance_extensions = &[_][*:0]const u8{
        vk.extensions.khr_get_surface_capabilities_2.name,
        vk.extensions.khr_surface_maintenance_1.name,
    },
    .device_extensions = &[_][*:0]const u8{
        vk.extensions.khr_swapchain.name,
        vk.extensions.khr_swapchain_maintenance_1.name,
    },
    .queueFamilyAcceptable = &queueFamilyAcceptable,
    .features = &[_]*vk.BaseOutStructure {
         @ptrCast(&swapchain_maintenance_1_features),
    },
};
