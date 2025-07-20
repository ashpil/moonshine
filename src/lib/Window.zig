// Thin wrapper for GLFW atm

const c = @import("glfw");
const vk = @import("vulkan");
const std = @import("std");

const Error = error {
    InitFail,
    WindowCreateFail,
    SurfaceCreateFail,
};

const Self = @This();

handle: *c.GLFWwindow,

pub fn create(width: u32, height: u32, app_name: [*:0]const u8) Error!Self {
    const Callback = struct {
        fn callback(code: c_int, message: [*c]const u8) callconv(.C) void {
            std.log.warn("glfw: {}: {s}", .{code, message});
        }
    };
    _ = c.glfwSetErrorCallback(Callback.callback);

    if (c.glfwInit() != c.GLFW_TRUE) return Error.InitFail;

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);

    const handle = c.glfwCreateWindow(@intCast(width), @intCast(height), app_name, null, null) orelse {
        c.glfwTerminate();
        return Error.WindowCreateFail;
    };

    return Self {
        .handle = handle,
    };
}

pub fn getPhysicalDevicePresentationSupport(instance: vk.Instance, device: vk.PhysicalDevice, idx: u32) bool {
    return c.glfwGetPhysicalDevicePresentationSupport(instance, device, idx) == c.GLFW_TRUE;
}

// abusing the fact a little bit that we know that glfw always asks for two extensions
pub fn getRequiredInstanceExtensions(self: *const Self) [2][*:0]const u8 {
    _ = self; // ensure we're initialized

    var glfw_extension_count: u32 = 0;
    const extensions = c.glfwGetRequiredInstanceExtensions(&glfw_extension_count);
    std.debug.assert(glfw_extension_count == 2);

    return @as([*]const [*:0]const u8, @ptrCast(extensions))[0..2].*;
}

pub fn shouldClose(self: *const Self) bool {
    return c.glfwWindowShouldClose(self.handle) == c.GLFW_TRUE;
}

pub const Mode = enum(c_int) {
    normal = c.GLFW_CURSOR_NORMAL,
    hidden = c.GLFW_CURSOR_HIDDEN,
    disabled = c.GLFW_CURSOR_DISABLED,
};
pub fn setCursorMode(self: *const Self, value: Mode) void {
    c.glfwSetInputMode(self.handle, c.GLFW_CURSOR, @intFromEnum(value));
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
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

pub fn destroy(self: *const Self) void {
    c.glfwDestroyWindow(self.handle);
    c.glfwTerminate();
}

