const vk = @import("vulkan");
const std = @import("std");
const core = @import("../engine.zig").core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const vk_helpers = core.vk_helpers;

const tracy_enabled = @import("build_options").tracy;
const tracy = @import("../tracy.zig");

const vk_map_memory_minimum_guaranteed_alignment = 64; // https://docs.vulkan.org/spec/latest/chapters/limits.html#limits-minmax may as well commuincate this to the compiler

fn heapName(properties: vk.MemoryPropertyFlags, writer: *std.Io.Writer) !void {
    var first = true;
    inline for (comptime std.meta.fieldNames(vk.MemoryPropertyFlags)) |name| {
        if (name[0] == '_') continue;
        if (@field(properties, name)) {
            if (!first) {
                try writer.writeByte('|');
            }
            const bit = "_bit";
            const bit_idx = std.mem.lastIndexOf(u8, name, bit).?;
            for (name[0..bit_idx]) |c| {
                try writer.writeByte(std.ascii.toUpper(c));
            }
            for (name[bit_idx + bit.len..]) |c| {
                try writer.writeByte(std.ascii.toUpper(c));
            }
            first = false;
        }
    }
}

fn heapNameSize(properties: vk.MemoryPropertyFlags) usize {
    var trash_buffer: [64]u8 = undefined;
    var dw: std.Io.Writer.Discarding = .init(&trash_buffer);
    heapName(properties, &dw.writer) catch |err| switch (err) {
        error.WriteFailed => unreachable,
    };
    return @intCast(dw.count + dw.writer.end);
}

pub fn comptimeHeapName(comptime properties: vk.MemoryPropertyFlags) *const [heapNameSize(properties):0]u8 {
    comptime {
        var buf: [heapNameSize(properties):0]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        heapName(properties, &w) catch unreachable;
        buf[buf.len] = 0;
        const final = buf;
        return &final;
    }
}

fn createRawBuffer(vc: *const VulkanContext, size: vk.DeviceSize, usage: vk.BufferUsageFlags, comptime properties: vk.MemoryPropertyFlags, name: [:0]const u8) !std.meta.Tuple(&.{ vk.Buffer, vk.DeviceMemory }) {
    const buffer = try vc.device.createBuffer(&.{
            .size = size,
            .usage = usage,
            .sharing_mode = vk.SharingMode.exclusive,
    }, null);
    errdefer vc.device.destroyBuffer(buffer, null);
    try vk_helpers.setDebugName(vc.device, buffer, name);

    const mem_requirements = vc.device.getBufferMemoryRequirements(buffer);

    const allocate_info = vk.MemoryAllocateInfo {
        .allocation_size = mem_requirements.size,
        .memory_type_index = try vc.memory_types.find(mem_requirements.memory_type_bits, properties),
        .p_next = if (usage.contains(.{ .shader_device_address_bit = true })) &vk.MemoryAllocateFlagsInfo {
            .device_mask = 0,
            .flags = .{ .device_address_bit = true },
        } else null,
    };

    const memory = try vc.device.allocateMemory(&allocate_info, null);
    errdefer vc.device.freeMemory(memory, null);
    if (tracy_enabled) tracy.memory.alloc(@intFromEnum(memory), mem_requirements.size, comptime comptimeHeapName(properties));
    try vk_helpers.setDebugName(vc.device, memory, name);

    try vc.device.bindBufferMemory(buffer, memory, 0);

    return .{ buffer, memory };
}

pub fn Buffer(comptime T: type, comptime memory_properties: vk.MemoryPropertyFlags, comptime usage: vk.BufferUsageFlags) type {
    const type_info = @typeInfo(T);
    if (type_info == .@"struct" and type_info.@"struct".layout == .auto) @compileError("Struct layout of " ++ @typeName(T) ++ " must be specified explicitly, but is not");

    const host_visible = memory_properties.contains(.{ .host_visible_bit = true });

    return struct {
        handle: vk.Buffer = .null_handle,
        memory: vk.DeviceMemory = .null_handle,
        mapped: if (host_visible) [*]T else void = if (host_visible) undefined else {},
        len: vk.DeviceSize = 0,

        const Self = @This();

        pub fn create(vc: *const VulkanContext, count: vk.DeviceSize, name: [:0]const u8) !Self {
            if (count == 0) return Self {};

            const size =  @sizeOf(T) * count;
            const buffer, const memory = try createRawBuffer(vc, size, usage, memory_properties, name);

            const mapped = if (host_visible) blk: {
                const ptr: [*]align(vk_map_memory_minimum_guaranteed_alignment) u8 = @alignCast(@ptrCast(try vc.device.mapMemory(memory, 0, vk.WHOLE_SIZE, .{})));
                break :blk @as([*]T, @ptrCast(ptr));
            } else ({});

            return Self {
                .handle = buffer,
                .memory = memory,
                .mapped = mapped,
                .len = count,
            };
        }

        pub fn destroy(self: Self, vc: *const VulkanContext) void {
            if (self.handle != .null_handle) {
                vc.device.destroyBuffer(self.handle, null);
                vc.device.freeMemory(self.memory, null);
                if (tracy_enabled) tracy.memory.free(@intFromEnum(self.memory), comptime comptimeHeapName(memory_properties));
            }
        }

        pub const getAddress = if (usage.contains(.{ .shader_device_address_bit = true })) struct {
            pub fn getAddress(self: Self, vc: *const VulkanContext) vk.DeviceAddress {
                return if (self.handle == .null_handle) 0 else vc.device.getBufferDeviceAddress(&.{
                    .buffer = self.handle,
                });
            }
        }.getAddress else struct {};

        const transfer = if (usage.contains(.{ .transfer_dst_bit = true })) struct {
            pub fn updateFrom(self: Self, encoder: *Encoder, dst_offset: vk.DeviceSize, src: []const T) void {
                const bytes = std.mem.sliceAsBytes(src);
                encoder.buffer.updateBuffer(self.handle, dst_offset * @sizeOf(T), bytes.len, src.ptr);
            }

            pub fn uploadFrom(self: Self, encoder: *Encoder, dst_offset: vk.DeviceSize, src: BufferSlice(T)) void {
                const region = vk.BufferCopy {
                    .src_offset = src.asBytes().offset,
                    .dst_offset = dst_offset * @sizeOf(T),
                    .size = src.asBytes().len,
                };

                encoder.buffer.copyBuffer(src.handle, self.handle, (&region)[0..1]);
            }
        } else struct {};

        pub const updateFrom = transfer.updateFrom;
        pub const uploadFrom = transfer.uploadFrom;

        pub const deviceSlice = if (usage.contains(.{ .transfer_src_bit = true }) or usage.contains(.{ .storage_buffer_bit = true })) struct {
            pub fn deviceSlice(self: Self) BufferSlice(T) {
                return BufferSlice(T) {
                    .handle = self.handle,
                    .offset = 0,
                    .len = self.len,
                };
            }
        }.deviceSlice else struct {};

        pub const hostSlice = if (host_visible) struct {
            pub fn hostSlice(self: Self) []T {
                return self.mapped[0..self.len];
            }
        }.hostSlice else struct {};

        pub fn isNull(self: Self) bool {
            return self.handle == .null_handle;
        }
    };
}

pub fn UploadBuffer(comptime T: type) type {
    return Buffer(T, vk.MemoryPropertyFlags { .host_visible_bit = true, .host_coherent_bit = true }, vk.BufferUsageFlags { .transfer_src_bit = true });
}

pub fn DownloadBuffer(comptime T: type) type {
    return Buffer(T, vk.MemoryPropertyFlags { .host_visible_bit = true, .host_coherent_bit = true, .host_cached_bit = true }, vk.BufferUsageFlags { .transfer_dst_bit = true });
}

pub fn DeviceBuffer(comptime T: type, comptime usage: vk.BufferUsageFlags) type {
    return Buffer(T, vk.MemoryPropertyFlags { .device_local_bit = true }, usage);
}

pub fn BufferSlice(comptime T: type) type {
    return struct {
        handle: vk.Buffer = .null_handle,
        offset: vk.DeviceSize = 0, // in bytes
        len: vk.DeviceSize = 0, // in T

        pub const descriptor_type: vk.DescriptorType = .storage_buffer;

        const Self = @This();

        pub fn asBytes(self: Self) BufferSlice(u8) {
            return BufferSlice(u8) {
                .handle = self.handle,
                .offset = self.offset,
                .len = @sizeOf(T) * self.len,
            };
        }

        pub fn slice(self: Self, start: vk.DeviceSize, end: vk.DeviceSize) BufferSlice(T) {
            std.debug.assert(start < end);
            std.debug.assert(end <= self.len);
            const offset = self.offset + start * @sizeOf(T);
            return BufferSlice(T) {
                .handle = self.handle,
                .offset = offset,
                .len = end - start,
            };
        }
    };
}

fn sliceContainsPtr(container: []const u8, ptr: [*]const u8) bool {
    return @intFromPtr(ptr) >= @intFromPtr(container.ptr) and
        @intFromPtr(ptr) < (@intFromPtr(container.ptr) + container.len);
}

pub fn HostVisiblePageAllocator(comptime memory_properties: vk.MemoryPropertyFlags, comptime usage: vk.BufferUsageFlags) type {
    if (comptime !memory_properties.contains(.{ .host_visible_bit = true})) @compileError("HostVisiblePageAllocator must only be used to allocate host visible memory");

    return struct {
        const Self = @This();

        const MemoryTypeIndex = std.meta.Int(.unsigned, vk.MAX_MEMORY_TYPES);
        const Metadata = struct {
            // technically the pointer here is entirely redundant as it basically points to itself
            // but std.Treap doesn't let me make use of this
            slice: []const u8,
            memory: vk.DeviceMemory,
            buffer: vk.Buffer,
        };
        const Allocations = std.Treap(Metadata, struct {
            fn compare(a: Metadata, b: Metadata) std.math.Order {
                return std.math.order(@intFromPtr(a.slice.ptr), @intFromPtr(b.slice.ptr));
            }
        }.compare);

        device: VulkanContext.Device,
        memory_type_index: MemoryTypeIndex,
        required_alignment_log2: std.math.Log2Int(vk.DeviceSize),
        allocations: Allocations = .{},

        pub fn init(vc: *const VulkanContext) Self {
            var memory_requirements = vk.MemoryRequirements2 {
                .memory_requirements = undefined,
            };
            vc.device.getDeviceBufferMemoryRequirements(&vk.DeviceBufferMemoryRequirements {
                .p_create_info = &vk.BufferCreateInfo {
                    .usage = usage,
                    .size = 0,
                    .sharing_mode = .exclusive,
                },
            }, &memory_requirements);

            const memory_type_index: MemoryTypeIndex = vc.memory_types.find(memory_requirements.memory_requirements.memory_type_bits, memory_properties) catch unreachable;

            return Self {
                .device = vc.device,
                .memory_type_index = memory_type_index,
                .required_alignment_log2 = std.math.log2_int(vk.DeviceSize, memory_requirements.memory_requirements.alignment), // vulkan guarantees this is a power of two,
                .allocations = Allocations {},
            };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = std.mem.Allocator.noResize,
                    .free = free,
                    .remap = std.mem.Allocator.noRemap,
                },
            };
        }

        pub fn getBufferSlice(self: Self, data: anytype) BufferSlice(@typeInfo(@TypeOf(data)).pointer.child) {
            const T = @typeInfo(@TypeOf(data)).pointer.child;

            const ptr = switch (@typeInfo(@TypeOf(data)).pointer.size) {
                .one => data,
                .slice => data.ptr,
                else => comptime unreachable,
            };

            const len = switch (@typeInfo(@TypeOf(data)).pointer.size) {
                .one => 1,
                .slice => data.len,
                else => comptime unreachable,
            };

            const node = self.findNode(@ptrCast(ptr));

            return BufferSlice(T) {
                .handle = node.key.buffer,
                .offset = @as([*]const u8, @ptrCast(ptr)) - node.key.slice.ptr,
                .len = len,
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            _ = ret_addr;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const required_alignment = alignment.toByteUnits();

            const worst_case_additional_memory_required = @max(@sizeOf(Allocations.Node), required_alignment);

            // > For a VkBuffer, the size memory requirement is never greater than the result of
            // > aligning VkBufferCreateInfo::size with the alignment memory requirement.
            const required_alignment_vk = @as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intCast(self.required_alignment_log2));
            const total_len = std.mem.alignForward(usize, len + worst_case_additional_memory_required, required_alignment_vk);
            const allocate_info = vk.MemoryAllocateInfo {
                .allocation_size = total_len,
                .memory_type_index = self.memory_type_index,
            };

            const memory = self.device.allocateMemory(&allocate_info, null) catch return null;
            const debug_name = blk: {
                const hex_bytes_per_bit = std.math.log2(16);
                const usize_hex_print_size =  @bitSizeOf(usize) / hex_bytes_per_bit;
                const alignment_hex_print_size =  @bitSizeOf(std.mem.Alignment) / hex_bytes_per_bit;
                const prefix = "[0x";
                const len_fmt = "{x:0>" ++ std.fmt.comptimePrint("{}", .{ usize_hex_print_size }) ++ "}";
                const infix = "]align(0x";
                const alignment_fmt = "{x:0>" ++ std.fmt.comptimePrint("{}", .{ alignment_hex_print_size }) ++ "}";
                const suffix = ")";
                var buf: [prefix.len + usize_hex_print_size + infix.len + alignment_hex_print_size + suffix.len + 1]u8 = undefined;
                break :blk std.fmt.bufPrintZ(&buf, prefix ++ len_fmt ++ infix ++ alignment_fmt ++ suffix, .{ len, required_alignment }) catch unreachable;
            };
            vk_helpers.setDebugName(self.device, memory, debug_name) catch |err| std.debug.panic("{}", .{ err });

            const ptr_unaligned: [*]align(vk_map_memory_minimum_guaranteed_alignment) u8 = @alignCast(@ptrCast(self.device.mapMemory(memory, 0, vk.WHOLE_SIZE, .{}) catch return null));

            if (tracy_enabled) tracy.memory.alloc(@intFromPtr(ptr_unaligned), total_len, comptime comptimeHeapName(memory_properties));

            const ptr_aligned = std.mem.alignPointer(ptr_unaligned + @sizeOf(Allocations.Node), required_alignment).?;

            const buffer = self.device.createBuffer(&.{
                .size = total_len,
                .usage = usage,
                .sharing_mode = .exclusive,
            }, null) catch return null;
            vk_helpers.setDebugName(self.device, buffer, debug_name) catch |err| std.debug.panic("{}", .{ err });

            self.device.bindBufferMemory(buffer, memory, 0) catch return null;

            const key = Metadata {
                .slice = ptr_unaligned[0..total_len],
                .memory = memory,
                .buffer = buffer,
            };
            var entry = self.allocations.getEntryFor(key);
            entry.set(self.getNode(ptr_aligned));

            return ptr_aligned;
        }

        fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            _ = alignment;
            _ = ret_addr;

            const self: *Self = @ptrCast(@alignCast(ctx));

            const node = self.getNode(buf.ptr);
            const buffer = node.key.buffer;
            const memory = node.key.memory;
            var entry = self.allocations.getEntryForExisting(node);
            entry.set(null);
            self.device.destroyBuffer(buffer, null);
            self.device.freeMemory(memory, null);
            if (tracy_enabled) tracy.memory.free(@intFromPtr(buf.ptr) - @sizeOf(Allocations.Node), comptime comptimeHeapName(memory_properties));
        }

        // for pointer returned by alloc
        // ptr must have come from this allocator
        fn getNode(_: Self, ptr: [*]u8) *Allocations.Node {
            return @ptrFromInt(@intFromPtr(ptr) - @sizeOf(Allocations.Node));
        }

        // for any pointer in allocation
        // ptr must have come from this allocator
        fn findNode(self: Self, ptr: [*]const u8) *Allocations.Node {
            var maybe_node = self.allocations.root;

            while (maybe_node) |node| {
                if (sliceContainsPtr(node.key.slice, ptr)) {
                    return node;
                } else {
                    const order = std.math.order(@intFromPtr(ptr), @intFromPtr(node.key.slice.ptr));
                    if (order == .eq) unreachable;
                    maybe_node = node.children[@intFromBool(order == .gt)];
                }
            }

            unreachable;
        }
    };
}

pub const UploadPageAllocator = HostVisiblePageAllocator(vk.MemoryPropertyFlags { .host_visible_bit = true, .host_coherent_bit = true }, vk.BufferUsageFlags { .transfer_src_bit = true });
pub const DownloadPageAllocator = HostVisiblePageAllocator(vk.MemoryPropertyFlags { .host_visible_bit = true, .host_coherent_bit = true, .host_cached_bit = true }, vk.BufferUsageFlags { .transfer_dst_bit = true });
