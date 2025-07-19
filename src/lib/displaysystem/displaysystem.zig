pub const Display = @import("./Display.zig");
pub const Swapchain = @import("./Swapchain.zig");

const vk = @import("vulkan");
const VulkanRequirements = @import("../engine.zig").core.VulkanContext.VulkanRequirements;
const Window = @import("../Window.zig");

fn queueFamilyAcceptable(instance: vk.Instance, device: vk.PhysicalDevice, idx: u32) bool {
    return Window.getPhysicalDevicePresentationSupport(instance, device, idx);
}

pub const vulkan_requirements = VulkanRequirements {
    .device_extensions = &[_][*:0]const u8{
        vk.extensions.khr_swapchain.name,
    },
    .queueFamilyAcceptable = &queueFamilyAcceptable,
};
