const std = @import("std");

const engine = @import("engine");

const core = engine.core;
const VulkanContext = core.VulkanContext;

const hrtsystem = engine.hrtsystem;

pub const vulkan_context_device_functions = hrtsystem.required_device_functions;

const Allocator = std.heap.GeneralPurposeAllocator(.{});

comptime {
    _ = HdMoonshine;
}

pub const HdMoonshine = struct {
    allocator: Allocator,
    vc: VulkanContext,

    pub export fn HdMoonshineCreate() ?*HdMoonshine {
        var allocator = Allocator {};
        const vc = VulkanContext.create(allocator.allocator(), "hdMoonshine", &.{}, &hrtsystem.required_device_extensions, &hrtsystem.required_device_features, null) catch return null;

        const self = allocator.allocator().create(HdMoonshine) catch return null;
        self.allocator = allocator;
        self.vc = vc;
        return self;
    }

    pub export fn HdMoonshineDestroy(self: *HdMoonshine) void {
        self.vc.destroy();
        var alloc = self.allocator;
        alloc.allocator().destroy(self);
        _ = alloc.deinit();
    }
};

