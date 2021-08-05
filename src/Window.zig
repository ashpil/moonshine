const c = @import("./c.zig");
const vk = @import("vulkan");

const Error = error {
    InitFail,
    WindowCreateFail,
    SurfaceCreateFail,
};

const Self = @This();

handle: *c.GLFWwindow,

pub fn create(size: vk.Extent2D) Error!Self {
    if (c.glfwInit() != c.GLFW_TRUE) return Error.InitFail;

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

    const handle = c.glfwCreateWindow(@intCast(c_int, size.width), @intCast(c_int, size.height), "Chess RTX", null, null) orelse {
        c.glfwTerminate();
        return Error.WindowCreateFail;
    };

    return Self {
        .handle = handle,
    };
}

pub fn shouldClose(self: *const Self) bool {
    return c.glfwWindowShouldClose(self.handle) == c.GLFW_TRUE;
}

pub fn pollEvents(self: *const Self) void {
    _ = self; // just ensure we're initialized
    c.glfwPollEvents();
}

pub fn createSurface(self: *const Self, instance: vk.Instance) Error!vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    if (c.glfwCreateWindowSurface(instance, self.handle, null, &surface) != vk.Result.success) return Error.SurfaceCreateFail; // this could give more details
    return surface;
}

pub fn getExtent(self: *const Self) vk.Extent2D {
    var width: c_int = undefined;
    var height: c_int = undefined;
    c.glfwGetWindowSize(self.handle, &width, &height);
    return vk.Extent2D {
        .width = @intCast(u32, width),
        .height = @intCast(u32, height),
    };
}

pub fn destroy(self: *Self) void {
    c.glfwDestroyWindow(self.handle);
    c.glfwTerminate();
}
