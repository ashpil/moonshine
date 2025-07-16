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

const color = @import("./color.zig");
const Vec2 = @import("vector.zig").Vec2;

pub const ImageDescription = struct {
    // cd/m^2
    minimum_luminance: f32,
    maximum_luminance: f32,
    reference_luminance: f32,

    primaries: color.Primaries,

    transfer_function: ?color.TransferFunction,
};

pub const ColorManager = if (@import("builtin").os.tag == .linux and @import("build_options").has_wayland) WaylandColorManager else NullColorManager;

pub const NullColorManager = struct {
    pub fn create(window: *const Self, allocator: std.mem.Allocator) !*const NullColorManager {
        _ = window;
        _ = allocator;
        return error.Unsupported;
    }

    pub fn destroy(self: *const NullColorManager, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn getImageDescription(self: *const NullColorManager) ImageDescription {
        _ = self;
        return undefined;
    }
};

const WaylandColorManager = struct {
    const wayland = @import("wayland").client;
    const wl = wayland.wl;
    const wp = wayland.wp;

    color_manager: *wp.ColorManagerV1,
    surface_feedback: *wp.ColorManagementSurfaceFeedbackV1,

    image_description: WaylandImageDescription,

    const WaylandImageDescription = struct {
        min_lum: u32,
        max_lum: u32,
        reference_lum: u32,

	primaries_named: wp.ColorManagerV1.Primaries,
        white: Vec2(i32),
        red: Vec2(i32),
        green: Vec2(i32),
        blue: Vec2(i32),

	transfer_function: wp.ColorManagerV1.TransferFunction,

        fn toImageDescription(self: WaylandImageDescription) ImageDescription {
            return ImageDescription {
                .minimum_luminance = @as(f32, @floatFromInt(self.min_lum)) / 10_000,
                .maximum_luminance = @floatFromInt(self.max_lum),
                .reference_luminance = @floatFromInt(self.reference_lum),

                .primaries = switch (self.primaries_named) {
                    .srgb => .{ .named = .srgb },
                    .pal_m => .{ .named = .pal_m },
                    .pal => .{ .named = .pal },
                    .ntsc => .{ .named = .ntsc },
                    .generic_film => .{ .named = .generic_film },
                    .bt2020 => .{ .named = .bt2020 },
                    .cie1931_xyz => .{ .named = .cie1931_xyz },
                    .dci_p3 => .{ .named = .dci_p3 },
                    .display_p3 => .{ .named = .display_p3 },
                    .adobe_rgb => .{ .named = .adobe_rgb },
                    else => .{ .parametric = .{
                        .red = self.red.floatFromInt(f32).scale(1.0 / 1_000_000.0),
                        .green = self.green.floatFromInt(f32).scale(1.0 / 1_000_000.0),
                        .blue = self.blue.floatFromInt(f32).scale(1.0 / 1_000_000.0),

                        .white = self.white.floatFromInt(f32).scale(1.0 / 1_000_000.0),
                    }},
                },
                .transfer_function = switch (self.transfer_function) {
                    .bt1886 => .bt1886,
                    .gamma22 => .gamma22,
                    .gamma28 => .gamma28,
                    .st240 => .st240,
                    .ext_linear => .ext_linear,
                    .log_100 => .log_100,
                    .log_316 => .log_316,
                    .xvycc => .xvycc,
                    .srgb => .srgb,
                    .ext_srgb => .ext_srgb,
                    .st2084_pq => .st2084_pq,
                    .st428 => .st428,
                    .hlg => .hlg,
                    _ => null,
                },
            };
        }
    };

    pub fn create(window: *const Self, allocator: std.mem.Allocator) !*const WaylandColorManager {
        const display = c.glfwGetWaylandDisplay() orelse return error.NotUsingWayland;

        const registry = try display.getRegistry();
        defer registry.destroy();

        var self = try allocator.create(WaylandColorManager);
        errdefer allocator.destroy(self);

	var color_manager: ?*wp.ColorManagerV1 = null;
        registry.setListener(*?*wp.ColorManagerV1, Listeners.registryListener, &color_manager);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        self.color_manager = color_manager orelse return error.ColorManagerNotFound;
        errdefer self.color_manager.destroy();

        const surface = c.glfwGetWaylandWindow(window.handle).?; // cannot return null if using wayland and glfw initialized

        self.surface_feedback = try self.color_manager.getSurfaceFeedback(surface);
        errdefer self.surface_feedback.destroy();
        self.surface_feedback.setListener(*WaylandColorManager, Listeners.surfaceFeedbackListener, self);

	// setup done; get initial information
        const description = try self.surface_feedback.getPreferredParametric();
        defer description.destroy();

        const info = try description.getInformation();
        errdefer info.destroy(); // destroyed in callback on success
        info.setListener(*WaylandColorManager, Listeners.imageDescriptionInfoListener, self);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        return self;
    }

    pub fn destroy(self: *const WaylandColorManager, allocator: std.mem.Allocator) void {
        self.surface_feedback.destroy();
        self.color_manager.destroy();
        allocator.destroy(self);
    }

    pub fn getImageDescription(self: *const WaylandColorManager) ImageDescription {
        return self.image_description.toImageDescription();
    }

    const Listeners = struct {
        fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *?*wp.ColorManagerV1) void {
            switch (event) {
                .global => |global| {
                    if (std.mem.orderZ(u8, global.interface, wp.ColorManagerV1.interface.name) == .eq) {
                        context.* = registry.bind(global.name, wp.ColorManagerV1, 1) catch return;
                    }
                },
                .global_remove => {},
            }
        }

        fn surfaceFeedbackListener(feedback: *wp.ColorManagementSurfaceFeedbackV1, event: wp.ColorManagementSurfaceFeedbackV1.Event, context: *WaylandColorManager) void {
            switch (event) {
                .preferred_changed => {
                    const description = feedback.getPreferredParametric() catch return;
                    defer description.destroy();

                    const info = description.getInformation() catch return;
                    info.setListener(*WaylandColorManager, imageDescriptionInfoListener, context);
                },
            }
        }

        fn imageDescriptionInfoListener(info: *wp.ImageDescriptionInfoV1, event: wp.ImageDescriptionInfoV1.Event, context: *WaylandColorManager) void {
            switch (event) {
                .luminances => |lum| {
                    context.image_description.min_lum = lum.min_lum;
                    context.image_description.max_lum = lum.max_lum;
                    context.image_description.reference_lum = lum.reference_lum;
                },
                .primaries => |primaries| {
                    context.image_description.red = Vec2(i32).new(.{ primaries.r_x, primaries.r_y });
                    context.image_description.green = Vec2(i32).new(.{ primaries.g_x, primaries.g_y });
                    context.image_description.blue = Vec2(i32).new(.{ primaries.b_x, primaries.b_y });

                    context.image_description.white = Vec2(i32).new(.{ primaries.w_x, primaries.w_y });
                },
                .primaries_named => |primaries_named| {
                    context.image_description.primaries_named = primaries_named.primaries;
                },
                .tf_named => |tf_named| {
                    context.image_description.transfer_function = tf_named.tf;
                },
                .done => {
                    info.destroy();
                },
                else => {},
            }
        }
    };
};
