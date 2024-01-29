const std = @import("std");
const vk = @import("vulkan");
const Gltf = @import("zgltf");

const engine = @import("../engine.zig");

const core = engine.core;
const VulkanContext = core.VulkanContext;
const VkAllocator = core.Allocator;
const Commands = core.Commands;

const Background = @import("./BackgroundManager.zig");
const World = @import("./World.zig");
const Camera = @import("./Camera.zig");

const exr = engine.fileformats.exr;

// must be kept in sync with shader
pub const DescriptorLayout = core.descriptor.DescriptorLayout(&.{
    .{ // TLAS
        .descriptor_type = .acceleration_structure_khr,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // instances
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // worldToInstance
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // emitterAliasTable
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // meshes
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // geometries
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // materialValues
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
        .binding_flags = .{ .partially_bound_bit = true },
    },
    .{ // backgroundImage
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
    .{ // backgroundMarginalAlias
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
    .{ // backgroundConditionalAlias
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
    .{ // outputImage
        .descriptor_type = .storage_image,
        .descriptor_count = 1,
        .stage_flags = .{ .raygen_bit_khr = true },
    },
}, .{ .push_descriptor_bit_khr = true }, 1, "Scene");

const Self = @This();

world: World,
background: Background,
camera: Camera,

descriptor_layout: DescriptorLayout,

// glTF doesn't correspond very well to the internal data structures here so this is very inefficient
// also very inefficient because it's written very inefficiently, can remove a lot of copying, but that's a problem for another time
// inspection bool specifies whether some buffers should be created with the `transfer_src_flag` for inspection
pub fn fromGlbExr(vc: *const VulkanContext, vk_allocator: *VkAllocator, allocator: std.mem.Allocator, commands: *Commands, glb_filepath: []const u8, skybox_filepath: []const u8, extent: vk.Extent2D, inspection: bool) !Self {
    var gltf = Gltf.init(allocator);
    defer gltf.deinit();

    const buffer = try std.fs.cwd().readFileAlloc(
        allocator,
        glb_filepath,
        std.math.maxInt(usize),
    );
    defer allocator.free(buffer);
    try gltf.parse(buffer);

    const camera_create_info = try Camera.Lens.fromGlb(gltf);
    var camera = try Camera.create();
    errdefer camera.destroy(vc, allocator);
    _ = try camera.appendLens(allocator, camera_create_info);
    _ = try camera.appendSensor(vc, vk_allocator, allocator, extent);

    var world = try World.fromGlb(vc, vk_allocator, allocator, commands, gltf, inspection);
    errdefer world.destroy(vc, allocator);

    var background = try Background.create(vc);
    errdefer background.destroy(vc, allocator);
    {
        const skybox_image = try exr.helpers.Rgba2D.load(allocator, skybox_filepath);
        defer allocator.free(skybox_image.asSlice());
        try background.addBackground(vc, vk_allocator, allocator, commands, skybox_image, "exr");
    }

    const descriptor_layout = try DescriptorLayout.create(vc, .{ background.sampler });
    errdefer descriptor_layout.destroy(vc);

    return Self {
        .world = world,
        .background = background,
        .camera = camera,

        .descriptor_layout = descriptor_layout,
    };
}

// TODO: put this into pipeline
pub fn pushDescriptors(self: *const Self, vc: *const VulkanContext, command_buffer: vk.CommandBuffer, layout: vk.PipelineLayout, sensor: u32, background: u32) void {
    const writes = [_]vk.WriteDescriptorSet {
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .acceleration_structure_khr,
            .p_image_info = undefined,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
            .p_next = &vk.WriteDescriptorSetAccelerationStructureKHR {
                .acceleration_structure_count = 1,
                .p_acceleration_structures = @ptrCast(&self.world.accel.tlas_handle),
            },
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = self.world.accel.instances_device.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 2,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = self.world.accel.world_to_instance.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        // vk.WriteDescriptorSet {
        //     .dst_set = undefined,
        //     .dst_binding = 3,
        //     .dst_array_element = 0,
        //     .descriptor_count = 1,
        //     .descriptor_type = .storage_buffer,
        //     .p_image_info = undefined,
        //     .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
        //         .buffer = self.world.accel.alias_table.handle,
        //         .offset = 0,
        //         .range = vk.WHOLE_SIZE,
        //     }),
        //     .p_texel_buffer_view = undefined,
        // },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 4,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = self.world.meshes.addresses_buffer.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 5,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = self.world.accel.geometries.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 6,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = self.world.materials.materials.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 7,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                .sampler = .null_handle,
                .image_view = self.background.data.items[background].image.view,
                .image_layout = .shader_read_only_optimal,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 8,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = self.background.data.items[background].marginal.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 9,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo {
                .buffer = self.background.data.items[background].conditional.handle,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }),
            .p_texel_buffer_view = undefined,
        },
        vk.WriteDescriptorSet {
            .dst_set = undefined,
            .dst_binding = 10,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = @ptrCast(&vk.DescriptorImageInfo {
                .sampler = .null_handle,
                .image_view = self.camera.sensors.items[sensor].image.view,
                .image_layout = .general,
            }),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }
    };
    vc.device.cmdPushDescriptorSetKHR(command_buffer, .ray_tracing_khr, layout, 1, writes.len, &writes);
}

pub fn destroy(self: *Self, vc: *const VulkanContext, allocator: std.mem.Allocator) void {
    self.descriptor_layout.destroy(vc);
    self.world.destroy(vc, allocator);
    self.background.destroy(vc, allocator);
    self.camera.destroy(vc, allocator);
}
