// wrappers around cimgui
const std = @import("std");
const vk = @import("vulkan");

const c = @import("../c.zig");
const Window = @import("../Window.zig");

const vector = @import("../vector.zig");
const F32x2 = vector.Vec2(f32);
const F32x3 = vector.Vec3(f32);

pub const DrawVert = c.ImDrawVert;
pub const DrawIdx = c.ImDrawIdx;
pub const Context = c.ImGuiContext;
pub const IO = c.ImGuiIO;
pub const FontAtlas = c.ImFontAtlas;
pub const DrawData = c.ImDrawData;
pub const Vec2 = c.ImVec2;
pub const MouseButton = enum(c_int) {
    left = c.ImGuiMouseButton_Left,
    right = c.ImGuiMouseButton_Right,
    middle = c.ImGuiMouseButton_Middle,
};

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

pub fn setNextWindowSize(width: f32, height: f32) void {
    _ = c.igSetNextWindowSize(c.ImVec2{
        .x = width,
        .y = height,
    }, c.ImGuiCond_FirstUseEver);
}

pub fn setNextWindowPos(x: f32, y: f32) void {
    _ = c.igSetNextWindowPos(c.ImVec2{
        .x = x,
        .y = y,
    }, c.ImGuiCond_FirstUseEver, c.ImVec2{
        .x = 0.0,
        .y = 0.0,
    });
}

pub fn text(msg: [*:0]const u8) void {
    c.igTextUnformatted(msg, null);
}

pub fn textFmt(comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const str = try std.fmt.bufPrintZ(&buf, fmt, args);
    c.igTextUnformatted(str, null);
}

pub fn separator() void {
    c.igSeparator();
}

pub fn separatorText(msg: [*:0]const u8) void {
    c.igSeparatorText(msg);
}

pub fn dragScalar(comptime T: type, label: [*:0]const u8, p_data: *T, v_speed: f32, min: T, max: T) bool {
    const data_type = switch (T) {
        u32 => c.ImGuiDataType_U32,
        f32 => c.ImGuiDataType_Float,
        else => unreachable, // TODO
    };
    const format = switch (T) {
        u32 => "%d",
        f32 => "%.2f",
        else => unreachable, // TODO
    };
    return c.igDragScalar(label, data_type, p_data, v_speed, &min, &max, format, c.ImGuiSliderFlags_AlwaysClamp);
}

pub fn dragVector(comptime T: type, label: [*:0]const u8, p_data: *T, v_speed: f32, min: T.Inner, max: T.Inner) bool {
    const data_type = switch (T.Inner) {
        u32 => c.ImGuiDataType_U32,
        f32 => c.ImGuiDataType_Float,
        else => unreachable, // TODO
    };
    const format = switch (T.Inner) {
        u32 => "%d",
        f32 => "%.2f",
        else => unreachable, // TODO
    };
    const component_count = T.element_count;

    return c.igDragScalarN(label, data_type, p_data, component_count, v_speed, &min, &max, format, c.ImGuiSliderFlags_AlwaysClamp);
}

pub fn sliderAngle(label: [*:0]const u8, p_rad: *f32, degrees_min: f32, degrees_max: f32) bool {
    return c.igSliderAngle(label, p_rad, degrees_min, degrees_max, "%.0f deg", c.ImGuiSliderFlags_AlwaysClamp);
}

pub fn inputScalar(comptime T: type, label: [*:0]const u8, p_data: *T, step: ?T, step_fast: ?T) bool {
    const data_type = switch (T) {
        u32 => c.ImGuiDataType_U32,
        else => unreachable, // TODO
    };
    return c.igInputScalar(label, data_type, p_data, if (step) |s| &s else null, if (step_fast) |s| &s else null, "%d", 0);
}

const Col = enum(c_int) {
    text,
    _,
};

pub fn pushStyleColor(idx: Col, color: vector.Vec4(f32)) void {
    c.igPushStyleColor_Vec4(@intFromEnum(idx), @bitCast(color));
}

pub fn popStyleColor() void {
    c.igPopStyleColor(1);
}

const ColorEditFlags = packed struct(c_int) {
    none: bool = false,
    no_alpha: bool = true,
    no_picker: bool = false,
    no_options: bool = false,
    no_small_preview: bool = false,
    no_inputs: bool = false,
    no_tooltip: bool = false,
    no_label: bool = false,
    no_side_preview: bool = false,
    no_drag_drop: bool = false,
    no_border: bool = false,

    _unused: u5 = 0,

    alpha_bar: bool = false,
    alpha_preview: bool = false,
    alpha_preview_half: bool = false,

    hdr: bool = true,

    display_rgb: bool = false,
    display_hsv: bool = false,
    display_hex: bool = false,

    uint8: bool = false,
    float: bool = true,

    picker_hue_bar: bool = false,
    picker_hue_wheel: bool = false,

    input_rgb: bool = false,
    input_hsv: bool = false,

    _unused2: u3 = 0,
};

pub fn colorEdit(label: [*:0]const u8, color: *F32x3, flags: ColorEditFlags) bool {
    return c.igColorEdit4(label, @ptrCast(color), @bitCast(flags));
}

pub fn getMouseDragDelta(mouse_button: MouseButton, lock_threshold: f32) F32x2 {
    var out: Vec2 = undefined;
    c.igGetMouseDragDelta(&out, @intFromEnum(mouse_button), lock_threshold);
    return @bitCast(out);
}

pub fn resetMouseDragDelta(mouse_button: MouseButton) void {
    c.igResetMouseDragDelta(@intFromEnum(mouse_button));
}

pub fn isMouseClicked(mouse_button: MouseButton) bool {
    return c.igIsMouseClicked_Bool(@intFromEnum(mouse_button), false);
}

pub fn getFontSize() f32 {
    return c.igGetFontSize();
}

pub fn pushItemWidth(width: f32) void {
    c.igPushItemWidth(width);
}

pub fn popItemWidth() void {
    c.igPopItemWidth();
}

pub fn alignTextToFramePadding() void {
    c.igAlignTextToFramePadding();
}

pub fn button(label: [*:0]const u8, size: Vec2) bool {
    return c.igButton(label, size);
}

pub fn smallButton(label: [*:0]const u8) bool {
    return c.igSmallButton(label);
}

pub fn getContentRegionAvail() Vec2 {
    var vec2: c.ImVec2 = undefined;
    c.igGetContentRegionAvail(&vec2);
    return vec2;
}

pub fn sameLine() void {
    c.igSameLine(0.0, -1.0);
}

pub fn collapsingHeader(label: [*:0]const u8) bool {
    return c.igCollapsingHeader_TreeNodeFlags(label, 0);
}

pub fn begin(name: [*:0]const u8) void {
    _ = c.igBegin(name, null, 0);
}

pub fn end() void {
    c.igEnd();
}

pub fn getTexDataAsAlpha8(self: *FontAtlas) std.meta.Tuple(&.{ [*]const u8, vk.Extent2D }) {
    var width: c_int = undefined;
    var height: c_int = undefined;
    var out_pixels: [*c]u8 = undefined;
    c.ImFontAtlas_GetTexDataAsAlpha8(self, &out_pixels, &width, &height, null);

    return .{ out_pixels, vk.Extent2D{ .width = @intCast(width), .height = @intCast(height) } };
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
