const c = @import("./c.zig");
const vk = @import("vulkan");

const Engine = @import("./Engine.zig");

const Error = error {
    InitFail,
    WindowCreateFail,
    SurfaceCreateFail,
};

const Self = @This();

handle: *c.GLFWwindow,

pub fn create(width: u32, height: u32) Error!Self {
    if (c.glfwInit() != c.GLFW_TRUE) return Error.InitFail;

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

    const handle = c.glfwCreateWindow(@intCast(c_int, width), @intCast(c_int, height), "Chess RTX", null, null) orelse {
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

pub fn setUserPointer(self: *const Self, ptr: *c_void) void {
    c.glfwSetWindowUserPointer(self.handle, ptr);
}

pub fn getUserPointer(self: *const Self) ?*c_void {
    return c.glfwGetWindowUserPointer(self.handle).?;
}

pub fn setResizeCallback(self: *const Self, comptime callback: fn (*const Self, vk.Extent2D) void) void {
    const Callback = struct {
        fn resizeCallback(handle: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
            const extent = vk.Extent2D {
                .width = @intCast(u32, width),
                .height = @intCast(u32, height),
            };
            const window = Self {
                .handle = handle.?,
            };
            callback(&window, extent);
        }
    };
    _ = c.glfwSetFramebufferSizeCallback(self.handle, Callback.resizeCallback);
}

pub const Action = enum(c_int) {
    release = 0,
    press = 1,
    repeat = 2,
};

pub fn setKeyCallback(self: *const Self, comptime callback: fn (*const Self, u32, Action) void) void {
    const Callback = struct {
        fn keyCallback(handle: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.C) void {
            _ = scancode;
            _ = mods;
            
            const window = Self {
                .handle = handle.?,
            };
            callback(&window, @intCast(u32, key), @intToEnum(Action, action));
        }
    };
    _ = c.glfwSetKeyCallback(self.handle, Callback.keyCallback);
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
    c.glfwGetFramebufferSize(self.handle, &width, &height);
    return vk.Extent2D {
        .width = @intCast(u32, width),
        .height = @intCast(u32, height),
    };
}

pub fn destroy(self: *const Self) void {
    c.glfwDestroyWindow(self.handle);
    c.glfwTerminate();
}
