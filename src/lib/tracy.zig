const c = @import("tracy");
const std = @import("std");

pub const memory = struct {
    pub fn alloc(buf: []const u8, pool_name: [:0]const u8) void {
        c.___tracy_emit_memory_alloc_callstack_named(buf.ptr, buf.len, 62, 0, pool_name);
    }

    pub fn free(ptr: [*]const u8, pool_name: [:0]const u8) void {
        c.___tracy_emit_memory_free_callstack_named(ptr, 62, 0, pool_name);
    }
};

pub const Allocator = struct {
    child_allocator: std.mem.Allocator,
    pool_name: [:0]const u8,

    pub fn allocator(self: *Allocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        const ret = self.child_allocator.rawAlloc(n, alignment, ra);

	if (ret) |ptr| memory.alloc(ptr[0..n], self.pool_name);

        return ret;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        const ret = self.child_allocator.rawResize(buf, alignment, new_len, ret_addr);
        if (ret) {
            memory.free(buf.ptr, self.pool_name);
            memory.alloc(buf, self.pool_name);
        }
        return ret;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        const ret = self.child_allocator.rawRemap(buf, alignment, new_len, return_address);
        if (ret) |new_buf| {
            memory.free(buf.ptr, self.pool_name);
            memory.alloc(new_buf[0..new_len], self.pool_name);
        }
        return ret;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        self.child_allocator.rawFree(buf, alignment, ret_addr);
        memory.free(buf.ptr, self.pool_name);
    }
};
