const gpu = @import("std").gpu;

const attributes = struct {
    const pos = @extern(*addrspace(.input) @Vector(2, f32), .{
        .name = "pos",
        .decoration = .{
            .location = 0,
        },
    });
    const uv = @extern(*addrspace(.input) @Vector(2, f32), .{
        .name = "uv",
        .decoration = .{
            .location = 1,
        },
    });
    const color = @extern(*addrspace(.input) @Vector(4, f32), .{
        .name = "color",
        .decoration = .{
            .location = 2,
        },
    });
};

const PushConstants = extern struct {
    scale: @Vector(2, f32),
    translate: @Vector(2, f32),
};

extern var push_constants: PushConstants addrspace(.push_constant);

const Out = extern struct {
    color: @Vector(4, f32),
    uv: @Vector(2, f32),
};

const out = @extern(*addrspace(.output) Out, .{
    .name = "out",
    .decoration = .{
        .location = 0,
    },
});

export fn main() callconv(.spirv_vertex) void {
    const transformed = attributes.pos.* * push_constants.scale + push_constants.translate;

    gpu.position_out.* = .{ transformed[0], transformed[1], 0.0, 1.0 };

    out.* = Out {
        .color = attributes.color.*,
        .uv = attributes.uv.*,
    };
}
