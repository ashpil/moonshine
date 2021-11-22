const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("./VulkanContext.zig");
const VkAllocator = @import("./Allocator.zig");
const Pipeline = @import("./Pipeline.zig");
const desc = @import("./descriptor.zig");
const Descriptor = desc.Descriptor(1);
const Commands = @import("./Commands.zig");
const Camera = @import("./Camera.zig");
const F32x2 = @import("../utils/zug.zig").Vec2(f32);

// TODO: restructure descriptor set so that we can use same set for TLAS here
// and in main render loop

const Self = @This();

buffer: VkAllocator.HostBuffer(u16),
pipeline: Pipeline,
descriptor: Descriptor,

command_pool: vk.CommandPool,
command_buffer: vk.CommandBuffer,

pub fn create(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: *std.mem.Allocator, commands: *Commands) !Self {
    const buffer = try vk_allocator.createHostBuffer(vc, u16, 1, .{ .storage_buffer_bit = true });

    const descriptor = try Descriptor.create(vc, [_]desc.BindingInfo {
        .{
            .stage_flags = .{ .raygen_bit_khr = true },
            .descriptor_type = .acceleration_structure_khr,
            .count = 1,
        },
        .{
            .stage_flags = .{ .raygen_bit_khr = true },
            .descriptor_type = .storage_buffer,
            .count = 1,
        },
    });

    const pipeline = try Pipeline.create(vc, vk_allocator, allocator, commands, descriptor.layout, &[_]Pipeline.ShaderInfoCreateInfo {
        .{ .stage = vk.ShaderStageFlags { .raygen_bit_khr = true }, .filepath = "../../zig-cache/shaders/misc/input.rgen.spv" },
        .{ .stage = vk.ShaderStageFlags { .miss_bit_khr = true }, .filepath = "../../zig-cache/shaders/misc/input.rmiss.spv" },
        .{ .stage = vk.ShaderStageFlags { .closest_hit_bit_khr = true }, .filepath = "../../zig-cache/shaders/misc/input.rchit.spv" },
    }, &[_]vk.PushConstantRange {
        .{
            .offset = 0,
            .size = @sizeOf(Camera.Desc) + @sizeOf(F32x2),
            .stage_flags = .{ .raygen_bit_khr = true },
        }
    });

    const command_pool = try vc.device.createCommandPool(.{
        .queue_family_index = vc.physical_device.queue_family_index,
        .flags = .{ .transient_bit = true },
    }, null);
    errdefer vc.device.destroyCommandPool(command_pool, null);

    var command_buffer: vk.CommandBuffer = undefined;
    try vc.device.allocateCommandBuffers(.{
        .level = vk.CommandBufferLevel.primary,
        .command_pool = command_pool,
        .command_buffer_count = 1,
    }, @ptrCast([*]vk.CommandBuffer, &command_buffer));

    return Self {
        .buffer = buffer,
        .descriptor = descriptor,
        .pipeline = pipeline,

        .command_pool = command_pool,
        .command_buffer = command_buffer,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.buffer.destroy(vc);
    self.pipeline.destroy(vc);
    self.descriptor.destroy(vc);
    vc.device.destroyCommandPool(self.command_pool, null);
}
