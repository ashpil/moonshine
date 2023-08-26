// Thin wrapper for GLFW atm

const c = @import("./c.zig");
const vk = @import("vulkan");
const std = @import("std");

const Error = error {
    InitFail,
    WindowCreateFail,
    SurfaceCreateFail,
};

const Self = @This();

pub const getInstanceProcAddress = c.glfwGetInstanceProcAddress;

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

pub fn initVulkanLoader(loader: vk.PfnGetInstanceProcAddr) void {
    return c.glfwInitVulkanLoader(loader);
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

pub fn setUserPointer(self: *const Self, ptr: *anyopaque) void {
    c.glfwSetWindowUserPointer(self.handle, ptr);
}

pub fn getUserPointer(self: *const Self) ?*anyopaque {
    return c.glfwGetWindowUserPointer(self.handle).?;
}

pub fn setAspectRatio(self: *const Self, numer: u32, denom: u32) void {
    c.glfwSetWindowAspectRatio(self.handle, @intCast(numer), @intCast(denom));
}

pub fn setResizeCallback(self: *const Self, comptime callback: fn (*const Self, vk.Extent2D) void) void {
    const Callback = struct {
        fn resizeCallback(handle: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
            const extent = vk.Extent2D {
                .width = @intCast(width),
                .height = @intCast(height),
            };
            const window = Self {
                .handle = handle.?,
            };
            callback(&window, extent);
        }
    };
    _ = c.glfwSetFramebufferSizeCallback(self.handle, Callback.resizeCallback);
}

pub fn setCursorPosCallback(self: *const Self, comptime callback: fn (*const Self, f64, f64) void) void {
    const Callback = struct {
        fn cursorPosCallback(handle: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.C) void {
            const window = Self {
                .handle = handle.?,
            };
            callback(&window, xpos, ypos);
        }
    };
    _ = c.glfwSetCursorPosCallback(self.handle, Callback.cursorPosCallback);
}

pub fn getCursorPos(self: *const Self) struct { x: f64, y: f64 } {
    var xpos: f64 = undefined;
    var ypos: f64 = undefined;

    c.glfwGetCursorPos(self.handle, &xpos, &ypos);

    return .{
        .x = xpos,
        .y = ypos,
    };
}

pub const Action = enum(c_int) {
    release = 0,
    press = 1,
    repeat = 2,
};

pub const MouseButton = enum(c_int) {
    left = 0,
    right = 1,
    middle = 2,
    _,
};

pub const ModifierKeys = packed struct(c_int) {
    shift: bool,
    control: bool,
    alt: bool,
    super: bool,
    caps_lock: bool,
    num_lock: bool,
    _unused: u26,
};

pub fn setMouseButtonCallback(self: *const Self, comptime callback: fn (*const Self, MouseButton, Action, ModifierKeys) void) void {
    const Callback = struct {
        fn mouseButtonCallback(handle: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.C) void {
            const window = Self {
                .handle = handle.?,
            };
            callback(&window, @enumFromInt(button), @enumFromInt(action), @bitCast(mods));
        }
    };
    _ = c.glfwSetMouseButtonCallback(self.handle, Callback.mouseButtonCallback);
}

pub fn setKeyCallback(self: *const Self, comptime callback: fn (*const Self, u32, Action, ModifierKeys) void) void {
    const Callback = struct {
        fn keyCallback(handle: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.C) void {
            _ = scancode;
            
            const window = Self {
                .handle = handle.?,
            };
            callback(&window, @intCast(key), @enumFromInt(action), @bitCast(mods));
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
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

pub fn destroy(self: *const Self) void {
    c.glfwDestroyWindow(self.handle);
    c.glfwTerminate();
}
