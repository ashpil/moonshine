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

pub fn checkbox(label: [*:0]const u8, value: *bool) bool {
    return c.igCheckbox(label, value);
}

pub fn dragScalar(comptime T: type, label: [*:0]const u8, p_data: *T, v_speed: f32, min: T, max: T) bool {
    const data_type = comptime switch (T) {
        u8 => c.ImGuiDataType_U8,
        u32 => c.ImGuiDataType_U32,
        f32 => c.ImGuiDataType_Float,
        else => unreachable, // TODO
    };
    const format = comptime switch (T) {
        u8, u32 => "%d",
        f32 => "%.2f",
        else => unreachable, // TODO
    };
    return c.igDragScalar(label, data_type, p_data, v_speed, &min, &max, format, c.ImGuiSliderFlags_AlwaysClamp);
}

pub fn dragMatrix(comptime T: type, comptime label: [*:0]const u8, p_data: *T, v_speed: f32, min: T.ComponentType, max: T.ComponentType) bool {
    const data_type = switch (T.ComponentType) {
        u32 => c.ImGuiDataType_U32,
        f32 => c.ImGuiDataType_Float,
        else => unreachable, // TODO
    };
    const format = switch (T.ComponentType) {
        u32 => "%d",
        f32 => "%.2f",
        else => unreachable, // TODO
    };

    var changed = false;
    if (T.row_count > 1 and T.col_count > 1) {
        text(label);
        inline for (0..T.row_count) |row_idx| {
            var row = p_data.row(row_idx).toArray();
            changed = c.igDragScalarN(std.fmt.comptimePrint("##{s}{}", .{ label, row_idx }), data_type, &row, T.col_count, v_speed, &min, &max, format, c.ImGuiSliderFlags_AlwaysClamp) or changed;
            inline for (0..T.col_count) |col_idx| {
                p_data.at_mut(.{ .row = row_idx, .col = col_idx}).* = row[col_idx];
            }
        }
    } else {
        var data = p_data.toArray();
        changed = c.igDragScalarN(label, data_type, &data, T.element_count, v_speed, &min, &max, format, c.ImGuiSliderFlags_AlwaysClamp) or changed;
        p_data.* = .new(data);
    }

    return changed;
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

pub fn beginCombo(label: [*:0]const u8, preview_value: [*:0]const u8) bool {
    return c.igBeginCombo(label, preview_value, 0);
}

pub fn endCombo() void {
    c.igEndCombo();
}

pub fn selectable(label: [*:0]const u8, selected: bool) bool {
    return c.igSelectable_Bool(label, selected, 0, c.ImVec2{ .x = 0, .y = 0 });
}

pub fn setItemDefaultFocus() void {
    c.igSetItemDefaultFocus();
}

pub fn enumCombo(comptime T: type, label: [*:0]const u8, data: *T) bool {
    const before = data.*;
    if (beginCombo(label, @tagName(data.*))) {
        inline for (@typeInfo(T).@"enum".fields) |field| {
            const selected = data.* == @as(T, @enumFromInt(field.value));
            if (selectable(field.name, selected)) data.* = @enumFromInt(field.value);
            if (selected) setItemDefaultFocus();
        }
        endCombo();
    }
    return before != data.*;
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

pub const Key = enum(c_uint) {
    a = c.ImGuiKey_A,
    b = c.ImGuiKey_B,
    c = c.ImGuiKey_C,
    d = c.ImGuiKey_D,
    e = c.ImGuiKey_E,
    f = c.ImGuiKey_F,
    g = c.ImGuiKey_G,
    h = c.ImGuiKey_H,
    i = c.ImGuiKey_I,
    j = c.ImGuiKey_J,
    k = c.ImGuiKey_K,
    l = c.ImGuiKey_L,
    m = c.ImGuiKey_M,
    n = c.ImGuiKey_N,
    o = c.ImGuiKey_O,
    p = c.ImGuiKey_P,
    q = c.ImGuiKey_Q,
    r = c.ImGuiKey_R,
    s = c.ImGuiKey_S,
    t = c.ImGuiKey_T,
    u = c.ImGuiKey_U,
    v = c.ImGuiKey_V,
    w = c.ImGuiKey_W,
    x = c.ImGuiKey_X,
    y = c.ImGuiKey_Y,
    z = c.ImGuiKey_Z,
    _,
};
pub fn isKeyDown(key: Key) bool {
    return c.igIsKeyDown_Nil(@intFromEnum(key));
}

pub const MouseCursor = enum(c_int) {
    none = c.ImGuiMouseCursor_None,
    arrow = c.ImGuiMouseCursor_Arrow,
    text_input = c.ImGuiMouseCursor_TextInput,
    resize_all = c.ImGuiMouseCursor_ResizeAll,
    resize_ns = c.ImGuiMouseCursor_ResizeNS,
    resize_ew = c.ImGuiMouseCursor_ResizeEW,
    resize_nesw = c.ImGuiMouseCursor_ResizeNESW,
    resize_nwse = c.ImGuiMouseCursor_ResizeNWSE,
    hand = c.ImGuiMouseCursor_Hand,
    not_allowed = c.ImGuiMouseCursor_NotAllowed,
};
pub fn setMouseCursor(cursor: MouseCursor) void {
    c.igSetMouseCursor(@intFromEnum(cursor));
}

pub const MouseButton = enum(c_int) {
    left = c.ImGuiMouseButton_Left,
    right = c.ImGuiMouseButton_Right,
    middle = c.ImGuiMouseButton_Middle,
};
pub fn getMouseDragDelta(mouse_button: MouseButton) F32x2 {
    var out: Vec2 = undefined;
    c.igGetMouseDragDelta(&out, @intFromEnum(mouse_button), -1);
    return @bitCast(out);
}

pub fn resetMouseDragDelta(mouse_button: MouseButton) void {
    c.igResetMouseDragDelta(@intFromEnum(mouse_button));
}

pub fn isMouseDragging(mouse_button: MouseButton) bool {
    return c.igIsMouseDragging(@intFromEnum(mouse_button), -1);
}

pub fn isMouseClicked(mouse_button: MouseButton) bool {
    return c.igIsMouseClicked_Bool(@intFromEnum(mouse_button), false);
}

pub fn isMouseReleased(mouse_button: MouseButton) bool {
    return c.igIsMouseReleased_Nil(@intFromEnum(mouse_button));
}

pub fn getMousePos() F32x2 {
    var out: Vec2 = undefined;
    c.igGetMousePos(&out);
    return @bitCast(out);
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

pub fn treeNode(label: [*:0]const u8) bool {
    return c.igTreeNode_Str(label);
}

pub fn treePop() void {
    c.igTreePop();
}

pub fn button(label: [*:0]const u8, size: Vec2) bool {
    return c.igButton(label, size);
}

pub fn smallButton(label: [*:0]const u8) bool {
    return c.igSmallButton(label);
}

pub fn beginDisabled() void {
    c.igBeginDisabled(true);
}

pub fn endDisabled() void {
    c.igEndDisabled();
}

pub fn setItemTooltip(str: [*:0]const u8) void {
    c.igSetItemTooltip(str);
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
    std.debug.assert(c.ImGui_ImplGlfw_InitForVulkan(window.handle, true));
}

pub fn implGlfwShutdown() void {
    c.ImGui_ImplGlfw_Shutdown();
}

pub fn implGlfwNewFrame() void {
    c.ImGui_ImplGlfw_NewFrame();
}
