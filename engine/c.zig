// Just includes from C -- happens here
// Changes based on engine features requested
const options = @import("build_options");

pub usingnamespace @cImport({
    if (options.gui) {
        @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", {});
        @cInclude("cimgui.h");
    }

    if (options.window) {
        @cDefine("GLFW_INCLUDE_NONE", {});
        @cInclude("GLFW/glfw3.h");
    }

    if (options.hrtsystem) {
        @cInclude("tinyexr.h");
    }
});

const c = @This();

const vk = @import("vulkan");

pub usingnamespace if (options.window) struct {
    pub extern fn glfwGetInstanceProcAddress(vk.Instance, [*:0]const u8) vk.PfnVoidFunction;
    pub extern fn glfwCreateWindowSurface(vk.Instance, *c.GLFWwindow, ?*const vk.AllocationCallbacks, *vk.SurfaceKHR) vk.Result;
    pub extern fn glfwGetPhysicalDevicePresentationSupport(vk.Instance, vk.PhysicalDevice, u32) c_int;
    pub extern fn glfwInitVulkanLoader(vk.PfnGetInstanceProcAddr) void;
} else struct {};

pub usingnamespace if (options.gui) struct {
    pub extern fn ImGui_ImplGlfw_InitForVulkan(*c.GLFWwindow, bool) bool;
    pub extern fn ImGui_ImplGlfw_Shutdown() void;
    pub extern fn ImGui_ImplGlfw_NewFrame() void;
} else struct {};
