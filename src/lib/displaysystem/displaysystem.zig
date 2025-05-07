pub const Display = @import("./Display.zig");
pub const Swapchain = @import("./Swapchain.zig");

const vk = @import("vulkan");

pub const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
};
