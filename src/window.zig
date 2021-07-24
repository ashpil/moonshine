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

pub fn destroy(self: *Self) void {
    c.glfwDestroyWindow(self.handle);
    c.glfwTerminate();
}
