// Just includes from C -- happens here
// Changes based on engine features requested

const windowing = @import("build_options").windowing;
const exr = @import("build_options").exr;

pub usingnamespace @cImport({
    if (windowing) {
        @cDefine("GLFW_INCLUDE_NONE", {});
        @cInclude("GLFW/glfw3.h");
    }

    if (exr) {
        @cInclude("tinyexr.h");
    }
});

const c = @This();
pub usingnamespace if (windowing) struct {
    const vk = @import("vulkan");

    pub extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction;
    pub extern fn glfwCreateWindowSurface(instance: vk.Instance, window: *c.GLFWwindow, allocation_callbacks: ?*const vk.AllocationCallbacks, surface: *vk.SurfaceKHR) vk.Result;
} else struct {};

