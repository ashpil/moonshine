pub usingnamespace @cImport({
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");
});

const c = @This();

const vk = @import("vulkan");

pub extern fn glfwGetInstanceProcAddress(vk.Instance, [*:0]const u8) vk.PfnVoidFunction;
pub extern fn glfwCreateWindowSurface(vk.Instance, *c.GLFWwindow, ?*const vk.AllocationCallbacks, *vk.SurfaceKHR) vk.Result;
pub extern fn glfwGetPhysicalDevicePresentationSupport(vk.Instance, vk.PhysicalDevice, u32) c_int;
pub extern fn glfwInitVulkanLoader(vk.PfnGetInstanceProcAddr) void;
