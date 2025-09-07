const c = @import("tracy");
const std = @import("std");

pub const memory = struct {
    pub fn alloc(buf: []const u8) void {
        c.___tracy_emit_memory_alloc_callstack(buf.ptr, buf.len, 62, 0);
    }

    pub fn free(ptr: [*]const u8) void {
        c.___tracy_emit_memory_free_callstack(ptr, 62, 0);
    }
};

pub const Allocator = struct {
    child_allocator: std.mem.Allocator,

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

	if (ret) |ptr| memory.alloc(ptr[0..n]);

        return ret;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        const ret = self.child_allocator.rawResize(buf, alignment, new_len, ret_addr);
        if (ret) {
            memory.free(buf.ptr);
            memory.alloc(buf);
        }
        return ret;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        const ret = self.child_allocator.rawRemap(buf, alignment, new_len, return_address);
        if (ret) |new_buf| {
            memory.free(buf.ptr);
            memory.alloc(new_buf[0..new_len]);
        }
        return ret;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        self.child_allocator.rawFree(buf, alignment, ret_addr);
        memory.free(buf.ptr);
    }
};
