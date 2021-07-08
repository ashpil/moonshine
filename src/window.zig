const c = @import("./c.zig");
const vk = @import("vulkan");

const GlfwError = error {
    InitFail,
    WindowCreateFail,
};

pub const Window = struct {
    handle: *c.GLFWwindow,

    pub fn create(width: u32, height: u32) GlfwError!Window {
        if (c.glfwInit() != c.GLFW_TRUE) return GlfwError.InitFail;

        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

        const handle = c.glfwCreateWindow(@intCast(c_int, width), @intCast(c_int, height), "Chess RTX", null, null) orelse {
            c.glfwTerminate();
            return GlfwError.WindowCreateFail;
        };

        return Window {
            .handle = handle,
        };
    }

    pub fn destroy(self: *Window) void {
        c.glfwDestroyWindow(self.handle);
        c.glfwTerminate();
    }
};
