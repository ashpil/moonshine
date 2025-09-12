const c = @import("tracy");
const std = @import("std");

const callstack_depth = 62;

// tracy actually allows these to be arbitrary IDs rather than pointers
pub const memory = struct {
    pub fn alloc(id: usize, len: usize, pool_name: [:0]const u8) void {
        c.___tracy_emit_memory_alloc_callstack_named(@ptrFromInt(id), len, callstack_depth, 0, pool_name);
    }

    pub fn free(id: usize, pool_name: [:0]const u8) void {
        c.___tracy_emit_memory_free_callstack_named(@ptrFromInt(id), callstack_depth, 0, pool_name);
    }
};

pub const Zone = struct {
    context: c.___tracy_c_zone_context,

    pub inline fn begin(comptime name: [:0]const u8, maybe_color: ?u32) Zone {
        const src = @src();
        const data = c.___tracy_source_location_data {
            .name = name,
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
            .color = if (maybe_color) |color| color else 0,
        };
        return Zone {
            .context = c.___tracy_emit_zone_begin_callstack(&data, callstack_depth, 1),
        };
    }

    pub fn end(self: Zone) void {
        c.___tracy_emit_zone_end(self.context);
    }
};

pub const GPUContext = struct {
    pub fn create(period_ns: f32) GPUContext {
        const data = c.___tracy_gpu_new_context_data {
            .gpuTime = 0,
            .period = period_ns,
            .context = 0,
            .flags = 1,
            .type = 2,
        };
        c.___tracy_emit_gpu_new_context_serial(&data);
        return GPUContext {};
    }
};

pub const gpu_zone = struct {
    pub inline fn mark(comptime name: [:0]const u8, maybe_color: ?u32, begin_time: u64, end_time: u64, context: u8) void {
        const src = @src();
        const srcloc = c.___tracy_source_location_data {
            .name = name,
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
            .color = if (maybe_color) |color| color else 0,
        };
        const begin_query_id = 0;
        const begin_data = c.___tracy_gpu_zone_begin_callstack_data {
            .srcloc = @intFromPtr(&srcloc),
            .depth = callstack_depth,
            .queryId = begin_query_id,
            .context = context,
        };
        c.___tracy_emit_gpu_zone_begin_callstack_serial(&begin_data);
        const end_query_id = 1;
        const end_data = c.___tracy_gpu_zone_end_data {
            .queryId = end_query_id,
            .context = context,
        };
        c.___tracy_emit_gpu_zone_end_serial(&end_data);

        const begin_time_data = c.___tracy_gpu_zone_end_data {
            .gpuTime = begin_time,
            .query_id = begin_query_id,
            .context = context,
        };
        c.___tracy_emit_gpu_time_serial(&begin_time_data);
        const end_time_data = c.___tracy_gpu_zone_end_data {
            .gpuTime = end_time,
            .query_id = end_query_id,
            .context = context,
        };
        c.___tracy_emit_gpu_time_serial(&end_time_data);
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
