const c = @import("tracy");
const std = @import("std");

// tracy actually allows these to be arbitrary IDs rather than pointers
pub const memory = struct {
    pub fn alloc(id: usize, len: usize, pool_name: [:0]const u8) void {
        c.___tracy_emit_memory_alloc_callstack_named(@ptrFromInt(id), len, 62, 0, pool_name);
    }

    pub fn free(id: usize, pool_name: [:0]const u8) void {
        c.___tracy_emit_memory_free_callstack_named(@ptrFromInt(id), 62, 0, pool_name);
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

	if (ret) |ptr| memory.alloc(@intFromPtr(ptr), n, self.pool_name);

        return ret;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        const ret = self.child_allocator.rawResize(buf, alignment, new_len, ret_addr);
        if (ret) {
            memory.free(@intFromPtr(buf.ptr), self.pool_name);
            memory.alloc(@intFromPtr(buf.ptr), buf.len, self.pool_name);
        }
        return ret;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        const ret = self.child_allocator.rawRemap(buf, alignment, new_len, return_address);
        if (ret) |new_buf| {
            memory.free(@intFromPtr(buf.ptr), self.pool_name);
            memory.alloc(@intFromPtr(new_buf), new_len, self.pool_name);
        }
        return ret;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        self.child_allocator.rawFree(buf, alignment, ret_addr);
        memory.free(@intFromPtr(buf.ptr), self.pool_name);
    }
};
