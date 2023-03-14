// wrappers around cimgui
const std = @import("std");
const vk = @import("vulkan");

const c = @import("./c.zig");
const Window = @import("./Window.zig");

pub const DrawVert = c.ImDrawVert;
pub const DrawIdx = c.ImDrawIdx;
pub const Context = c.ImGuiContext;
pub const IO = c.ImGuiIO;
pub const FontAtlas = c.ImFontAtlas;
pub const DrawData = c.ImDrawData;

pub fn createContext() void {
    _ = c.igCreateContext(null);
}

pub fn destroyContext() void {
    c.igDestroyContext(null);
}

pub fn getCurrentContext() ?*Context {
    return c.igGetCurrentContext();
}

pub fn getIO() *IO {
    return c.igGetIO();
}

pub fn getDrawData() *DrawData {
    const draw_data = c.igGetDrawData();
    std.debug.assert(draw_data != null); // if fails, didn't call `Render` prior to this
    return draw_data;
}

pub fn render() void {
    c.igRender();
}

pub fn newFrame() void {
    c.igNewFrame();
}

pub fn showDemoWindow() void {
    c.igShowDemoWindow(null);
}

pub fn getTexDataAsAlpha8(self: *FontAtlas) std.meta.Tuple(&.{ [*]const u8, vk.Extent2D }) {
    var width: c_int = undefined;
    var height: c_int = undefined;
    var out_pixels: [*c]u8 = undefined;
    c.ImFontAtlas_GetTexDataAsAlpha8(self, &out_pixels, &width, &height, null);

    return .{ out_pixels, vk.Extent2D { .width = @intCast(u32, width), .height = @intCast(u32, height) } };
}

pub fn implGlfwInit(window: Window) void {
    var var_window = window;
    std.debug.assert(c.ImGui_ImplGlfw_InitForVulkan(var_window.handle, true));
}

pub fn implGlfwShutdown() void {
    c.ImGui_ImplGlfw_Shutdown();
}

pub fn implGlfwNewFrame() void {
    c.ImGui_ImplGlfw_NewFrame();
}
