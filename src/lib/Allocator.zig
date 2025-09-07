const builtin = @import("builtin");
const std = @import("std");
const TracyAllocator = @import("./tracy.zig").Allocator;

const use_debug_allocator = builtin.mode == .Debug;
const tracy_enabled = @import("build_options").tracy;

const Self = @This();

inner: if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void,
tracy: if (tracy_enabled) TracyAllocator else void,

pub fn init() Self {
    return Self {
        .inner = if (use_debug_allocator) .{} else {},
        .tracy = if (tracy_enabled) TracyAllocator {
            .child_allocator = undefined,
            .pool_name = "HOST",
        } else {},
    };
}

pub fn deinit(self: *Self) void {
    _ = if (use_debug_allocator) self.inner.deinit() else void;
}

pub fn allocator(self: *Self) std.mem.Allocator {
    const inner = if (use_debug_allocator) self.inner.allocator() else std.heap.smp_allocator;
    return if (tracy_enabled) blk: {
        self.tracy.child_allocator = inner;
        break :blk self.tracy.allocator();
    } else inner;
}

