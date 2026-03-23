// wrappers around cimgui
const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("glfw");

const c = @import("imgui");

extern fn ImGui_ImplGlfw_InitForVulkan(*glfw.GLFWwindow, bool) bool;
extern fn ImGui_ImplGlfw_Shutdown() void;
extern fn ImGui_ImplGlfw_NewFrame() void;

const Window = @import("../Window.zig");

const vector = @import("../vector.zig");
const F32x2 = vector.Vec2(f32);
const F32x3 = vector.Vec3(f32);
const U8x4 = vector.Vec4(u8);

pub const DrawVert = c.ImDrawVert;
pub const DrawIdx = c.ImDrawIdx;
pub const Context = c.ImGuiContext;
pub const IO = c.ImGuiIO;
pub const FontAtlas = c.ImFontAtlas;
pub const DrawData = c.ImDrawData;
pub const Vec2 = c.ImVec2;

pub fn createContext() void {
    _ = c.ImGui_CreateContext(null);
}

pub fn destroyContext() void {
    c.ImGui_DestroyContext(null);
}

pub fn getCurrentContext() ?*Context {
    return c.ImGui_GetCurrentContext();
}

pub fn getIO() *IO {
    return c.ImGui_GetIO();
}

pub fn getDrawData() *DrawData {
    const draw_data = c.ImGui_GetDrawData();
    std.debug.assert(draw_data != null); // if fails, didn't call `Render` prior to this
    return draw_data;
}

pub fn render() void {
    c.ImGui_Render();
}

pub fn newFrame() void {
    c.ImGui_NewFrame();
}

pub fn showDemoWindow() void {
    c.ImGui_ShowDemoWindow(null);
}

pub fn setNextWindowSize(width: f32, height: f32) void {
    _ = c.ImGui_SetNextWindowSize(c.ImVec2{
        .x = width,
        .y = height,
    }, c.ImGuiCond_FirstUseEver);
}

pub fn setNextWindowPos(x: f32, y: f32) void {
    _ = c.ImGui_SetNextWindowPos(c.ImVec2{
        .x = x,
        .y = y,
    }, c.ImGuiCond_FirstUseEver, c.ImVec2{
        .x = 0.0,
        .y = 0.0,
    });
}

pub fn getWindowDrawList() *c.ImDrawList {
    return c.ImGui_GetWindowDrawList();
}

pub fn getCursorScreenPos() F32x2 {
    return @bitCast(c.ImGui_GetCursorScreenPos());
}

pub fn setCursorScreenPos(pos: F32x2) void {
    return c.ImGui_SetCursorScreenPos(@bitCast(pos));
}

pub fn addPolyline(draw_list: *c.ImDrawList, points: []const F32x2, color: U8x4) void {
    c.ImDrawList_AddPolyline(draw_list, @ptrCast(points.ptr), @intCast(points.len), @bitCast(color), 0, 1.0);
}

pub fn addTriangle(draw_list: *c.ImDrawList, p1: F32x2, p2: F32x2, p3: F32x2, color: U8x4) void {
    c.ImDrawList_AddTriangle(draw_list, @bitCast(p1), @bitCast(p2), @bitCast(p3), @bitCast(color), 1.0);
}

pub fn addCircle(draw_list: *c.ImDrawList, center: F32x2, radius: f32, color: U8x4) void {
    c.ImDrawList_AddCircle(draw_list, @bitCast(center), radius, @bitCast(color), 0, 1.0);
}

pub fn addRect(draw_list: *c.ImDrawList, min: F32x2, max: F32x2, color: U8x4, rounding: f32, flags: c.ImDrawFlags, thickness: f32) void {
    c.ImDrawList_AddRect(draw_list, @bitCast(min), @bitCast(max), @bitCast(color), rounding, flags, thickness);
}

pub fn primReserve(draw_list: *c.ImDrawList, idx_count: usize, vtx_count: usize) void {
    c.ImDrawList_PrimReserve(draw_list, @intCast(idx_count), @intCast(vtx_count));
}

pub fn primWriteVtx(draw_list: *c.ImDrawList, pos: F32x2, uv: F32x2, col: U8x4) void {
    c.ImDrawList_PrimWriteVtx(draw_list, @bitCast(pos), @bitCast(uv), @bitCast(col));
}

pub fn primWriteIdx(draw_list: *c.ImDrawList, idx: c.ImDrawIdx) void {
    c.ImDrawList_PrimWriteIdx(draw_list, idx);
}

pub fn text(msg: [*:0]const u8) void {
    c.ImGui_TextUnformatted(msg, null);
}

pub fn textFmt(comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const str = try std.fmt.bufPrintZ(&buf, fmt, args);
    c.ImGui_TextUnformatted(str, null);
}

pub fn separator() void {
    c.ImGui_Separator();
}

pub fn separatorText(msg: [*:0]const u8) void {
    c.ImGui_SeparatorText(msg);
}

pub fn checkbox(label: [*:0]const u8, value: *bool) bool {
    return c.ImGui_Checkbox(label, value);
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
    return c.ImGui_DragScalar(label, data_type, p_data, v_speed, &min, &max, format, c.ImGuiSliderFlags_AlwaysClamp);
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
            changed = c.ImGui_DragScalarN(std.fmt.comptimePrint("##{s}{}", .{ label, row_idx }), data_type, &row, T.col_count, v_speed, &min, &max, format, c.ImGuiSliderFlags_AlwaysClamp) or changed;
            inline for (0..T.col_count) |col_idx| {
                p_data.at_mut(.{ .row = row_idx, .col = col_idx}).* = row[col_idx];
            }
        }
    } else {
        var data = p_data.toArray();
        changed = c.ImGui_DragScalarN(label, data_type, &data, T.element_count, v_speed, &min, &max, format, c.ImGuiSliderFlags_AlwaysClamp) or changed;
        p_data.* = .new(data);
    }

    return changed;
}

pub fn sliderAngle(label: [*:0]const u8, p_rad: *f32, degrees_min: f32, degrees_max: f32) bool {
    return c.ImGui_SliderAngle(label, p_rad, degrees_min, degrees_max, "%.0f deg", c.ImGuiSliderFlags_AlwaysClamp);
}

pub fn inputScalar(comptime T: type, label: [*:0]const u8, p_data: *T, step: ?T, step_fast: ?T) bool {
    const data_type = switch (T) {
        u32 => c.ImGuiDataType_U32,
        else => unreachable, // TODO
    };
    return c.ImGui_InputScalar(label, data_type, p_data, if (step) |s| &s else null, if (step_fast) |s| &s else null, "%d", 0);
}

pub fn beginCombo(label: [*:0]const u8, preview_value: [*:0]const u8) bool {
    return c.ImGui_BeginCombo(label, preview_value, 0);
}

pub fn endCombo() void {
    c.ImGui_EndCombo();
}

pub fn selectable(label: [*:0]const u8, selected: bool) bool {
    return c.ImGui_Selectable(label, selected, 0, c.ImVec2{ .x = 0, .y = 0 });
}

pub fn setItemDefaultFocus() void {
    c.ImGui_SetItemDefaultFocus();
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

pub fn getStyle() *c.ImGuiStyle {
    return c.ImGui_GetStyle();
}

pub fn pushStyleColor(idx: Col, color: vector.Vec4(f32)) void {
    c.ImGui_PushStyleColorImVec4(@intFromEnum(idx), @bitCast(color));
}

pub fn popStyleColor() void {
    c.ImGui_PopStyleColor(1);
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
    var rgba = [4]f32{ color.element(0), color.element(1), color.element(2), 1.0 };
    const result = c.ImGui_ColorEdit4(label, &rgba, @bitCast(flags));
    color.* = F32x3.new(.{ rgba[0], rgba[1], rgba[2] });
    return result;
}

pub const Key = enum(c_int) {
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
    tab = c.ImGuiKey_Tab,
    left_arrow = c.ImGuiKey_LeftArrow,
    right_arrow = c.ImGuiKey_RightArrow,
    up_arrow = c.ImGuiKey_UpArrow,
    down_arrow = c.ImGuiKey_DownArrow,
    page_up = c.ImGuiKey_PageUp,
    page_down = c.ImGuiKey_PageDown,
    home = c.ImGuiKey_Home,
    end = c.ImGuiKey_End,
    insert = c.ImGuiKey_Insert,
    delete = c.ImGuiKey_Delete,
    backspace = c.ImGuiKey_Backspace,
    space = c.ImGuiKey_Space,
    enter = c.ImGuiKey_Enter,
    escape = c.ImGuiKey_Escape,
    left_ctrl = c.ImGuiKey_LeftCtrl,
    left_shift = c.ImGuiKey_LeftShift,
    left_alt = c.ImGuiKey_LeftAlt,
    left_super = c.ImGuiKey_LeftSuper,
    right_ctrl = c.ImGuiKey_RightCtrl,
    right_shift = c.ImGuiKey_RightShift,
    right_alt = c.ImGuiKey_RightAlt,
    right_super = c.ImGuiKey_RightSuper,
    menu = c.ImGuiKey_Menu,
    @"0" = c.ImGuiKey_0,
    @"1" = c.ImGuiKey_1,
    @"2" = c.ImGuiKey_2,
    @"3" = c.ImGuiKey_3,
    @"4" = c.ImGuiKey_4,
    @"5" = c.ImGuiKey_5,
    @"6" = c.ImGuiKey_6,
    @"7" = c.ImGuiKey_7,
    @"8" = c.ImGuiKey_8,
    @"9" = c.ImGuiKey_9,
    _,
};

pub fn isKeyDown(key: Key) bool {
    return c.ImGui_IsKeyDown(@intFromEnum(key));
}

pub fn isKeyPressed(key: Key) bool {
    return c.ImGui_IsKeyPressed(@intFromEnum(key), false);
}

pub fn isKeyReleased(key: Key) bool {
    return c.ImGui_IsKeyReleased(@intFromEnum(key));
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
    c.ImGui_SetMouseCursor(@intFromEnum(cursor));
}

pub const MouseButton = enum(c_int) {
    left = c.ImGuiMouseButton_Left,
    right = c.ImGuiMouseButton_Right,
    middle = c.ImGuiMouseButton_Middle,
};
pub fn getMouseDragDelta(mouse_button: MouseButton) F32x2 {
    return @bitCast(c.ImGui_GetMouseDragDelta(@intFromEnum(mouse_button), -1));
}

pub fn resetMouseDragDelta(mouse_button: MouseButton) void {
    c.ImGui_ResetMouseDragDelta(@intFromEnum(mouse_button));
}

pub fn isMouseDragging(mouse_button: MouseButton) bool {
    return c.ImGui_IsMouseDragging(@intFromEnum(mouse_button), -1);
}

pub fn isMouseClicked(mouse_button: MouseButton) bool {
    return c.ImGui_IsMouseClicked(@intFromEnum(mouse_button), false);
}

pub fn isMouseReleased(mouse_button: MouseButton) bool {
    return c.ImGui_IsMouseReleased(@intFromEnum(mouse_button));
}

pub fn getMousePos() F32x2 {
    return @bitCast(c.ImGui_GetMousePos());
}

pub fn getFontSize() f32 {
    return c.ImGui_GetFontSize();
}

pub fn pushItemWidth(width: f32) void {
    c.ImGui_PushItemWidth(width);
}

pub fn popItemWidth() void {
    c.ImGui_PopItemWidth();
}

pub fn alignTextToFramePadding() void {
    c.ImGui_AlignTextToFramePadding();
}

pub fn treeNode(label: [*:0]const u8) bool {
    return c.ImGui_TreeNode(label);
}

pub fn treePop() void {
    c.ImGui_TreePop();
}

pub fn button(label: [*:0]const u8, size: Vec2) bool {
    return c.ImGui_Button(label, size);
}

pub fn smallButton(label: [*:0]const u8) bool {
    return c.ImGui_SmallButton(label);
}

pub fn beginDisabled() void {
    c.ImGui_BeginDisabled(true);
}

pub fn endDisabled() void {
    c.ImGui_EndDisabled();
}

pub fn setItemTooltip(str: [*:0]const u8) void {
    c.ImGui_SetItemTooltip(str);
}

pub fn getContentRegionAvail() F32x2 {
    return @bitCast(c.ImGui_GetContentRegionAvail());
}

pub fn sameLine() void {
    c.ImGui_SameLine(0.0, -1.0);
}

pub fn collapsingHeader(label: [*:0]const u8) bool {
    return c.ImGui_CollapsingHeader(label, 0);
}

pub fn begin(name: [*:0]const u8) void {
    _ = c.ImGui_Begin(name, null, 0);
}

pub fn end() void {
    c.ImGui_End();
}

pub fn getTexDataAsAlpha8(self: *FontAtlas) std.meta.Tuple(&.{ [*]const u8, vk.Extent2D }) {
    var width: c_int = undefined;
    var height: c_int = undefined;
    var out_pixels: [*c]u8 = undefined;
    c.ImFontAtlas_GetTexDataAsAlpha8(self, &out_pixels, &width, &height, null);

    return .{ out_pixels, vk.Extent2D{ .width = @intCast(width), .height = @intCast(height) } };
}

pub fn implGlfwInit(window: Window) void {
    std.debug.assert(ImGui_ImplGlfw_InitForVulkan(window.handle, true));
}

pub fn implGlfwShutdown() void {
    ImGui_ImplGlfw_Shutdown();
}

pub fn implGlfwNewFrame() void {
    ImGui_ImplGlfw_NewFrame();
}
