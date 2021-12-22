const std = @import("std");

const Engine = @import("./renderer/Engine.zig");
const Input = @import("./renderer/Input.zig");
const ChessSet = @import("./logic/ChessSet.zig");
const zug = @import("./utils/zug.zig");
const F32x3 = zug.Vec3(f32);
const Mat4 = zug.Mat4(f32);
const Window = @import("./utils/Window.zig");
const Camera = @import("./renderer/Camera.zig");
const vk = @import("vulkan");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const texture_sets = comptime [_]ChessSet.Material {
        ChessSet.Material {
            .color = .{
                .filepath = "../../assets/textures/board/color.dds",
            },
            .roughness = .{
                .greyscale = 0.3,
            },
            .normal = .{
                .filepath = "../../assets/textures/board/normal.dds"
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
    };

    const window = try Window.create(800, 600);
    defer window.destroy();

    var engine = try Engine.create(texture_sets.len, &window, allocator);
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

    var set = try ChessSet.create(&engine.context, &engine.allocator, allocator, &engine.commands, &texture_sets, "../../assets/textures/skybox.dds", set_info);
    defer set.destroy(&engine.context, allocator);

    var window_data = WindowData {
        .engine = &engine,
        .set = &set,
        .click = null,
    };

    var input = try Input.create(&engine.context, &engine.allocator, allocator, &engine.commands);
    defer input.destroy(&engine.context);

    window.setUserPointer(&window_data);
    window.setKeyCallback(keyCallback);
    window.setMouseButtonCallback(mouseButtonCallback);

    try engine.setScene(allocator, &set.scene);

    while (!window.shouldClose()) {
        const buffer = try engine.startFrame(&window, allocator);
        try set.scene.accel.applyChanges(&engine.context, buffer);
        try engine.recordFrame(buffer);
        var clicked = false;
        if (window_data.click) |click| {
            _ = click;
            window_data.click = null;
            clicked = true;
        }
        try engine.endFrame(&window, allocator);
        if (clicked) {
            std.debug.print("Instance clicked: {}\n", .{input.buffer.data[0]});
            clicked = false;
        }
        window.pollEvents();
    }
    try engine.context.device.deviceWaitIdle();

    std.log.info("Program completed!.", .{});
}

const ClickData = struct {
    x: u32,
    y: u32,
};

const WindowData = struct {
    engine: *Engine,
    set: *ChessSet,
    click: ?ClickData,
};

fn mouseButtonCallback(window: *const Window, button: Window.MouseButton, action: Window.Action) void {
    const ptr = window.getUserPointer().?;
    const window_data = @ptrCast(*WindowData, @alignCast(@alignOf(WindowData), ptr));

    if (button == .left and action == .press) {
        const pos = window.getCursorPos();
        window_data.click = .{
            .x = @floatToInt(u32, pos.x),
            .y = @floatToInt(u32, pos.y),
        };
    }
}

fn keyCallback(window: *const Window, key: u32, action: Window.Action) void {
    const ptr = window.getUserPointer().?;
    const window_data = @ptrCast(*WindowData, @alignCast(@alignOf(WindowData), ptr));
    const engine = window_data.engine;
    const set = window_data.set;
    if (action == .repeat or action == .press) {
        if (key == 65 or key == 68 or key == 83 or key == 87) {
            const move_amount = 1.0 / 18.0;
            var mat: Mat4 = undefined;
            if (key == 65) {
                mat = Mat4.fromAxisAngle(-move_amount, F32x3.new(0.0, 1.0, 0.0));
            } else if (key == 68) {
                mat = Mat4.fromAxisAngle(move_amount, F32x3.new(0.0, 1.0, 0.0));
            } else if (key == 83) {
                const target_dir = engine.camera_create_info.origin.sub(engine.camera_create_info.target);
                const axis = engine.camera_create_info.up.cross(target_dir).unit();
                if (F32x3.new(0.0, -1.0, 0.0).dot(target_dir.unit()) > 0.99) {
                    return;
                }
                mat = Mat4.fromAxisAngle(move_amount, axis);
            } else if (key == 87) {
                const target_dir = engine.camera_create_info.origin.sub(engine.camera_create_info.target);
                const axis = engine.camera_create_info.up.cross(target_dir).unit();
                if (F32x3.new(0.0, 1.0, 0.0).dot(target_dir.unit()) > 0.99) {
                    return;
                }
                mat = Mat4.fromAxisAngle(-move_amount, axis);
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
        } else if (key == 32) {
            set.move(5, @import("./logic/coord.zig").Coord.d4.toTransform()) catch unreachable;
        } else return;

        engine.camera = Camera.new(engine.camera_create_info);

        engine.num_accumulted_frames = 0;
    }
}
