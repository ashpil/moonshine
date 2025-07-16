const gpu = @import("std").gpu;

const Input = extern struct {
    color: @Vector(4, f32),
    uv: @Vector(2, f32),
};

extern var asd: u32 addrspace(.input);

const in = @extern(*addrspace(.input) Input, .{
    .name = "input",
    .decoration = .{
        .location = 0,
    },
});

const f_color = @extern(*addrspace(.output) @Vector(4, f32), .{
    .name = "output",
    .decoration = .{
        .location = 0,
    },
});

export fn main() callconv(.spirv_fragment) void {
    f_color.* = in.color * @as(@Vector(4, f32), @splat(sampler2d(0, 0, in.uv)[0]));
}

fn sampler2d(
    comptime set: u32,
    comptime bind: u32,
    uv: @Vector(2, f32),
) @Vector(4, f32) {
    return asm volatile (
        \\%float          = OpTypeFloat 32
        \\%v4float        = OpTypeVector %float 4
        \\%img_type       = OpTypeImage %float 2D 0 0 0 1 Unknown
        \\%sampler_type   = OpTypeSampledImage %img_type
        \\%sampler_ptr    = OpTypePointer UniformConstant %sampler_type
        \\%tex            = OpVariable %sampler_ptr UniformConstant
        \\                  OpDecorate %tex DescriptorSet $set
        \\                  OpDecorate %tex Binding $bind
        \\%loaded_sampler = OpLoad %sampler_type %tex
        \\%ret            = OpImageSampleImplicitLod %v4float %loaded_sampler %uv
        : [ret] "" (-> @Vector(4, f32)),
        : [uv] "" (uv),
          [set] "c" (set),
          [bind] "c" (bind),
    );
}
