const vk = @import("vulkan");
const std = @import("std");
const VulkanContext = @import("./VulkanContext.zig");
const build_options = @import("build_options");

fn typeToObjectType(comptime in: type) vk.ObjectType {
    return switch(in) {
        vk.DescriptorSetLayout => .descriptor_set_layout,
        vk.DescriptorSet => .descriptor_set,
        vk.Buffer => .buffer,
        vk.CommandBuffer => .command_buffer,
        else => unreachable, // TODO: add more
    };
}

pub fn setDebugName(vc: *const VulkanContext, object: anytype, name: [*:0]const u8) !void {
   if (comptime build_options.vk_validation) {
       try vc.device.setDebugUtilsObjectNameEXT(&.{
           .object_type = comptime typeToObjectType(@TypeOf(object)),
           .object_handle = @enumToInt(object),
           .p_object_name = name,
       });
   }
}

pub fn toPointerType(in: anytype) [*]const @typeInfo(@TypeOf(in)).Pointer.child {
    return @ptrCast([*]const @typeInfo(@TypeOf(in)).Pointer.child, in);
}

pub fn imageSizeInBytes(format: vk.Format, extent: vk.Extent2D) u32 {
    return switch (format) {
        .r32_sfloat => 1 * @sizeOf(f32) * extent.width * extent.height,
        .r32g32_sfloat => 2 * @sizeOf(f32) * extent.width * extent.height,
        .r32g32b32_sfloat => 3 * @sizeOf(f32) * extent.width * extent.height,
        .r32g32b32a32_sfloat => 4 * @sizeOf(f32) * extent.width * extent.height,
        else => unreachable, // TODO
    };
}

// creates shader modules, respecting build option to statically embed or dynamically load shader code
pub fn createShaderModules(vc: *const VulkanContext, comptime shader_names: []const []const u8, allocator: std.mem.Allocator) ![shader_names.len]vk.ShaderModule {
    const shaders = @import("shaders");

    var modules: [shader_names.len]vk.ShaderModule = undefined;
    inline for (shader_names, &modules) |shader_name, *module| {
        var to_free: []const u8 = undefined;
        defer if (build_options.shader_source == .load) allocator.free(to_free);
        const shader_code = if (build_options.shader_source == .embed) @field(shaders, shader_name) else blk: {
            var compile_process = std.ChildProcess.init(build_options.shader_compile_cmd ++ &[_][]const u8 { "shaders/" ++ shader_name }, allocator);
            compile_process.stdout_behavior = .Pipe;
            try compile_process.spawn();
            const stdout = blk_inner: {
                var poller = std.io.poll(allocator, enum { stdout }, .{ .stdout = compile_process.stdout.? });
                defer poller.deinit();

                while (try poller.poll()) {}

                var fifo = poller.fifo(.stdout);
                if (fifo.head > 0) {
                    std.mem.copy(u8, fifo.buf[0..fifo.count], fifo.buf[fifo.head .. fifo.head + fifo.count]);
                }

                to_free = fifo.buf;
                const stdout = fifo.buf[0..fifo.count];
                fifo.* = std.io.PollFifo.init(allocator);

                break :blk_inner stdout;
            };

            const term = try compile_process.wait();
            if (term == .Exited and term.Exited != 0) return error.ShaderCompileFail;
            break :blk stdout;
        };
        module.* = try vc.device.createShaderModule(&.{
            .code_size = shader_code.len,
            .p_code = @ptrCast([*]const u32, @alignCast(@alignOf(u32), if (build_options.shader_source == .embed) &shader_code else shader_code.ptr)),
        }, null);
    }
    return modules;
}

fn GetVkSliceInternal(comptime func: anytype) type {
    const params = @typeInfo(@TypeOf(func)).Fn.params;
    const OptionalType = params[params.len - 1].type.?;
    const PtrType = @typeInfo(OptionalType).Optional.child;
    return @typeInfo(PtrType).Pointer.child;
}

fn GetVkSliceBoundedReturn(comptime max_size: comptime_int, comptime func: anytype) type {
    const FuncReturn = @typeInfo(@TypeOf(func)).Fn.return_type.?;

    const BaseReturn = std.BoundedArray(GetVkSliceInternal(func), max_size);

    return switch (@typeInfo(FuncReturn)) {
        .ErrorUnion => |err| err.error_set!BaseReturn,
        .Void => BaseReturn,
        else => unreachable,
    };
}

// wrapper around functions like vkGetPhysicalDeviceSurfacePresentModesKHR
// they have some initial args, then a length and output address
// this is designed for small stuff to allocate on stack, where size maximum size is comptime known
//
// in optimized modes, only calls the actual function only once, based on the assumption that the caller correctly predicts max possible return size.
// in safe modes, checks that the actual size does not exceed the maximum size, which may call the function more than once
pub fn getVkSliceBounded(comptime max_size: comptime_int, func: anytype, partial_args: anytype) GetVkSliceBoundedReturn(max_size, func) {
    const T = GetVkSliceInternal(func);
    
    var buffer: [max_size]T = undefined;
    var len: u32 = max_size;

    const always_succeeds = @typeInfo(@TypeOf(func)).Fn.return_type == void;
    if (always_succeeds) {
        if (std.debug.runtime_safety) {
            var actual_len: u32 = undefined;
            @call(.auto, func, partial_args ++ .{ &actual_len, null });
            std.debug.assert(actual_len < max_size);
        }
        @call(.auto, func, partial_args ++ .{ &len, &buffer });
    } else {
        const res = try @call(.auto, func, partial_args ++ .{ &len, &buffer });
        std.debug.assert(res != .incomplete);
    }

    return std.BoundedArray(T, max_size) {
        .buffer = buffer,
        .len = len,
    };
}

pub fn getVkSlice(allocator: std.mem.Allocator, func: anytype, partial_args: anytype) ![]GetVkSliceInternal(func) {
    const T = GetVkSliceInternal(func);

    var len: u32 = undefined;
    _ = try @call(.auto, func, partial_args ++ .{ &len, null });

    const buffer = try allocator.alloc(T, len);

    const res = try @call(.auto, func, partial_args ++ .{ &len, buffer.ptr });
    std.debug.assert(res != .incomplete);

    return buffer;
}
