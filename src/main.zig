const std = @import("std");

const Engine = @import("./renderer/Engine.zig");
const Input = @import("./renderer/Input.zig");
const ChessSet = @import("./logic/ChessSet.zig");
const zug = @import("./utils/zug.zig");
const F32x3 = zug.Vec3(f32);
const F32x2 = zug.Vec2(f32);
const Mat4 = zug.Mat4(f32);
const Mat3x4 = zug.Mat3x4(f32);
const Vec3 = zug.Vec3(f32);
const Window = @import("./utils/Window.zig");
const Camera = @import("./renderer/Camera.zig");
const Coord = @import("./logic/coord.zig").Coord;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const texture_sets = comptime [_]ChessSet.Material {
        ChessSet.Material {
            .color = .{
                .dds_filepath = "../../assets/textures/board/color.dds",
            },
            .roughness = .{
                .greyscale = 0.3,
            },
            .normal = .{
                .dds_filepath = "../../assets/textures/board/normal.dds"
            },
            .metallic = 0.4,
            .ior = 1.35,
        },
        ChessSet.Material {
            .color = .{
                .color = F32x3.new(0.653, 0.653, 0.653)
            },
            .roughness = .{
                .greyscale = 0.15,
            },
            .normal = .{
                .color = F32x3.new(0.5, 0.5, 1.0)
            },
            .metallic = 0.2,
            .ior = 1.5,
        },
        ChessSet.Material {
            .color = .{
                .color = F32x3.new(0.0004, 0.0025, 0.0096)
            },
            .roughness = .{
                .greyscale = 0.15,
            },
            .normal = .{
                .color = F32x3.new(0.5, 0.5, 1.0)
            },
            .metallic = 0.2,
            .ior = 1.5,
        },
        ChessSet.Material {
            .color = .{
                .color = F32x3.new(0.901, 0.722, 0.271)
            },
            .roughness = .{
                .greyscale = 0.05,
            },
            .normal = .{
                .color = F32x3.new(0.5, 0.5, 1.0)
            },
            .metallic = 0.6,
            .ior = 1.5,
        },
    };

    const window = try Window.create(800, 600);
    defer window.destroy();

    var engine = try Engine.create(&window, allocator);
    defer engine.destroy(allocator);

    const set_info = ChessSet.SetInfo {
        .board = .{
            .material_index = 0,
            .model_path = "../../assets/models/board.obj"
        },

        .pawn = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/pawn.obj"
        },
        .rook = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/rook.obj"
        },
        .knight = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/knight.obj"
        },
        .bishop = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/bishop.obj"
        },
        .king = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/king.obj"
        },
        .queen = .{
            .white_material_index = 1,
            .black_material_index = 2,
            .model_path = "../../assets/models/queen.obj"
        },
    };

    var set = try ChessSet.create(&engine.context, &engine.allocator, allocator, &engine.commands, &texture_sets, "../../assets/textures/skybox/", set_info, &engine.scene_descriptor_layout, &engine.background_descriptor_layout);
    defer set.destroy(&engine.context, allocator);

    var input = try Input.create(&engine.context, &engine.allocator, allocator, engine.scene_descriptor_layout.handle, &engine.commands);
    defer input.destroy(&engine.context);

    var window_data = WindowData {
        .engine = &engine,
        .set = &set,
        .input = &input,
        .clicked = null,
    };

    window.setUserPointer(&window_data);
    window.setKeyCallback(keyCallback);
    window.setMouseButtonCallback(mouseButtonCallback);

    var active_piece: ?u16 = null;

    while (!window.shouldClose()) {
        const buffer = try engine.startFrame(&window, allocator);
        engine.setScene(&set.scene, buffer);
        if (window_data.clicked) |click_data| {
            if (click_data.instance_index > 0) {
                const instance_index = @intCast(u16, click_data.instance_index);
                if (active_piece) |active_piece_index| {
                    if (instance_index == active_piece_index) {
                        active_piece = null;
                    } else {
                        set.scene.accel.recordInstanceUpdate(&engine.context, buffer, instance_index, 3);
                        active_piece = instance_index;
                    }
                    if (Color.fromIndex(active_piece_index) == .white) {
                        set.scene.accel.recordInstanceUpdate(&engine.context, buffer, active_piece_index, 1);
                    } else {
                        set.scene.accel.recordInstanceUpdate(&engine.context, buffer, active_piece_index, 2);
                    }
                } else {
                    set.scene.accel.recordInstanceUpdate(&engine.context, buffer, instance_index, 3);
                    active_piece = instance_index;
                }
                engine.num_accumulted_frames = 0;
            } else if (click_data.instance_index == 0 and (click_data.primitive_index == 11 or click_data.primitive_index == 5)) {
                if (active_piece) |active_piece_index| {
                    const barycentrics = F32x3.new(1.0 - click_data.barycentrics.x - click_data.barycentrics.y, click_data.barycentrics.x, click_data.barycentrics.y);

                    var p1: F32x3 = undefined;
                    var p2: F32x3 = undefined;

                    const edge = Coord.board_size / 2.0;
                    if (click_data.primitive_index == 11) {
                        p1 = F32x3.new(-edge, edge, edge);
                        p2 = F32x3.new(-edge, -edge, edge);
                    } else if (click_data.primitive_index == 5) {
                        p1 = F32x3.new(-edge, edge, -edge);
                        p2 = F32x3.new(-edge, edge, edge);
                    }

                    const location = F32x2.new(p1.dot(barycentrics), p2.dot(barycentrics));
                    var transform = Coord.fromLocation(location).toTransform();
                    if (Color.fromIndex(active_piece_index) == .black) {
                        transform = transform.mul(Mat3x4.from_rotation(Vec3.new(0.0, 1.0, 0.0), std.math.pi));
                    }
                    set.move(active_piece_index, transform);
                    engine.num_accumulted_frames = 0;
                }
            } else if (click_data.instance_index == -1) {
                if (active_piece) |active_piece_index| {
                    set.changeVisibility(active_piece_index, false);
                    active_piece = null;
                    engine.num_accumulted_frames = 0;
                }
            }
            window_data.clicked = null;
        }
        try set.scene.accel.recordChanges(&engine.context, buffer);
        try engine.recordFrame(buffer);
        try engine.endFrame(&window, allocator);
        window.pollEvents();
    }
    try engine.context.device.deviceWaitIdle();

    std.log.info("Program completed!.", .{});
}

pub const Color = enum {
    black,
    white,

    pub fn fromIndex(index: u32) Color {
        if (index < 9 or index == 17 or index == 21 or index == 25 or index == 31 or index == 29 or index == 26 or index == 22 or index == 18) {
            return .white;
        } else {
            return .black;
        }
    }
};

const WindowData = struct {
    engine: *Engine,
    set: *ChessSet,
    input: *Input,
    clicked: ?Input.ClickData,
};

fn mouseButtonCallback(window: *const Window, button: Window.MouseButton, action: Window.Action) void {
    const ptr = window.getUserPointer().?;
    const window_data = @ptrCast(*WindowData, @alignCast(@alignOf(WindowData), ptr));

    if (button == .left and action == .press) {
        const pos = window.getCursorPos();
        const x = @floatCast(f32, pos.x) / @intToFloat(f32, window_data.engine.display.extent.width);
        const y = @floatCast(f32, pos.y) / @intToFloat(f32, window_data.engine.display.extent.height);
        window_data.clicked = window_data.input.getClick(&window_data.engine.context, F32x2.new(x, y), window_data.engine.camera, window_data.set.scene.descriptor_set) catch unreachable;
    }
}

fn keyCallback(window: *const Window, key: u32, action: Window.Action) void {
    const ptr = window.getUserPointer().?;
    const window_data = @ptrCast(*WindowData, @alignCast(@alignOf(WindowData), ptr));
    const engine = window_data.engine;
    if (action == .repeat or action == .press) {
        if (key == 65 or key == 68 or key == 83 or key == 87) {
            const move_amount = 1.0 / 18.0;
            var mat: Mat4 = undefined;
            if (key == 65) {
                mat = Mat4.fromAxisAngle(F32x3.new(0.0, 1.0, 0.0), -move_amount);
            } else if (key == 68) {
                mat = Mat4.fromAxisAngle(F32x3.new(0.0, 1.0, 0.0), move_amount);
            } else if (key == 83) {
                const target_dir = engine.camera_create_info.origin.sub(engine.camera_create_info.target);
                const axis = engine.camera_create_info.up.cross(target_dir).unit();
                if (F32x3.new(0.0, -1.0, 0.0).dot(target_dir.unit()) > 0.99) {
                    return;
                }
                mat = Mat4.fromAxisAngle(axis, move_amount);
            } else if (key == 87) {
                const target_dir = engine.camera_create_info.origin.sub(engine.camera_create_info.target);
                const axis = engine.camera_create_info.up.cross(target_dir).unit();
                if (F32x3.new(0.0, 1.0, 0.0).dot(target_dir.unit()) > 0.99) {
                    return;
                }
                mat = Mat4.fromAxisAngle(axis, -move_amount);
            } else unreachable;

            engine.camera_create_info.origin = mat.mul_point(engine.camera_create_info.origin.sub(engine.camera_create_info.target)).add(engine.camera_create_info.target);
        } else if (key == 70 and engine.camera_create_info.aperture > 0.0) {
            engine.camera_create_info.aperture -= 0.0005;
        } else if (key == 82) {
            engine.camera_create_info.aperture += 0.0005;
        } else if (key == 81) {
            engine.camera_create_info.focus_distance -= 0.01;
        } else if (key == 69) {
            engine.camera_create_info.focus_distance += 0.01;
        } else return;

        engine.camera = Camera.new(engine.camera_create_info);

        engine.num_accumulted_frames = 0;
    }
}
