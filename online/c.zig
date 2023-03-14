pub usingnamespace @cImport({
    // imgui
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", {});
    @cInclude("cimgui.h");
    
    // GLFW
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cInclude("GLFW/glfw3.h");
});

const c = @This();

const vk = @import("vulkan");

pub extern fn glfwGetInstanceProcAddress(vk.Instance, [*:0]const u8) vk.PfnVoidFunction;
pub extern fn glfwCreateWindowSurface(vk.Instance, *c.GLFWwindow, ?*const vk.AllocationCallbacks, *vk.SurfaceKHR) vk.Result;
pub extern fn glfwGetPhysicalDevicePresentationSupport(vk.Instance, vk.PhysicalDevice, u32) c_int;
pub extern fn glfwInitVulkanLoader(vk.PfnGetInstanceProcAddr) void;

pub extern fn ImGui_ImplGlfw_InitForVulkan(*c.GLFWwindow, bool) bool;
pub extern fn ImGui_ImplGlfw_Shutdown() void;
pub extern fn ImGui_ImplGlfw_NewFrame() void;