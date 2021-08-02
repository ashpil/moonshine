const c = @import("./c.zig");
const vk = @import("vulkan");

const GlfwError = error {
    InitFail,
    WindowCreateFail,
};

const Self = @This();

handle: *c.GLFWwindow,

pub fn create(size: vk.Extent2D) GlfwError!Self {
    if (c.glfwInit() != c.GLFW_TRUE) return GlfwError.InitFail;

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

    const handle = c.glfwCreateWindow(@intCast(c_int, size.width), @intCast(c_int, size.height), "Chess RTX", null, null) orelse {
        c.glfwTerminate();
        return GlfwError.WindowCreateFail;
    };

    return Self {
        .handle = handle,
    };
}

// TODO: error checking
pub fn shouldClose(self: *const Self) bool {
    return c.glfwWindowShouldClose(self.handle) != 0;
}

pub fn pollEvents(self: *const Self) void {
    _ = self; // just ensure we're initialized
    c.glfwPollEvents();
}

pub fn createSurface(self: *const Self, instance: vk.Instance) vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    _ = c.glfwCreateWindowSurface(instance, self.handle, null, &surface);
    return surface;
}

pub fn destroy(self: *Self) void {
    c.glfwDestroyWindow(self.handle);
    c.glfwTerminate();
}
