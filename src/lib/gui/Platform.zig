// imgui platform implementation

const vk = @import("vulkan");
const std = @import("std");

const engine = @import("../engine.zig");
const core = engine.core;
const VulkanContext = core.VulkanContext;
const Encoder = core.Encoder;
const vk_helpers = core.vk_helpers;

const Image = core.Image;
const DescriptorLayout = core.descriptor.DescriptorLayout;

const Swapchain = engine.displaysystem.Swapchain;
const Display = engine.displaysystem.Display;

const vector = engine.vector;
const F32x3 = vector.Vec3(f32);

const imgui = @import("./imgui.zig");
const Window = @import("../Window.zig");

const frames_in_flight = Display.frames_in_flight;
const Self = @This();

const VertexBuffer = core.mem.Buffer(imgui.DrawVert, .{ .host_visible_bit = true, .host_coherent_bit = true }, .{ .vertex_buffer_bit =  true });
const IndexBuffer = core.mem.Buffer(imgui.DrawIdx, .{ .host_visible_bit = true, .host_coherent_bit = true }, .{ .index_buffer_bit =  true });

descriptor_set_layout: GuiDescriptorLayout,
pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,

font_sampler: vk.Sampler,
font_image: Image,
font_image_set: vk.DescriptorSet,

vertex_buffers: [frames_in_flight]VertexBuffer,
index_buffers: [frames_in_flight]IndexBuffer,

pub fn create(vc: *const VulkanContext, format: vk.Format, window: Window, encoder: *Encoder) !Self {
    if (imgui.getCurrentContext()) |_| @panic("cannot create more than one Gui");

    imgui.createContext();
    imgui.implGlfwInit(window);
    imgui.getIO().IniFilename = null;

    // load required vulkan state
    const font_sampler = try vc.device.createSampler(&.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .min_lod = -1000,
        .max_lod = 1000,
        .anisotropy_enable = .false,
        .max_anisotropy = 1.0,
        .compare_enable = .false,
        .compare_op = .never,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = .false,
        .mip_lod_bias = 0.0,
    }, null);

    const descriptor_set_layout = try GuiDescriptorLayout.create(vc, .{ font_sampler });

    const pipeline_layout = try vc.device.createPipelineLayout(&vk.PipelineLayoutCreateInfo {
        .set_layout_count = 1,
        .p_set_layouts = (&descriptor_set_layout.handle)[0..1],
        .push_constant_range_count = 1,
        .p_push_constant_ranges = (&vk.PushConstantRange{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(f32) * 4,
        })[0..1],
    }, null);

    const pipeline = blk: {
        const vertex = @import("platform_shaders").vertex.code;
        const vert_module = try vc.device.createShaderModule(&.{
            .code_size = vertex.len * @sizeOf(u32),
            .p_code = vertex.ptr,
        }, null);
        defer vc.device.destroyShaderModule(vert_module, null);
        try vk_helpers.setDebugName(vc.device, vert_module, "gui vertex");

        const fragment = @import("platform_shaders").fragment.code;
        const frag_module = try vc.device.createShaderModule(&.{
            .code_size = fragment.len * @sizeOf(u32),
            .p_code = fragment.ptr,
        }, null);
        defer vc.device.destroyShaderModule(frag_module, null);
        try vk_helpers.setDebugName(vc.device, frag_module, "gui fragment");

        const shader_stage_create_info = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .module = vert_module,
                .stage = .{ .vertex_bit = true },
                .p_name = "main",
            },
            .{
                .module = frag_module,
                .stage = .{ .fragment_bit = true },
                .p_name = "main",
            },
        };
        const vertex_attribute_descriptions = [_]vk.VertexInputAttributeDescription{
            .{
                .location = 0,
                .binding = 0,
                .format = .r32g32_sfloat,
                .offset = @offsetOf(imgui.DrawVert, "pos"),
            },
            .{
                .location = 1,
                .binding = 0,
                .format = .r32g32_sfloat,
                .offset = @offsetOf(imgui.DrawVert, "uv"),
            },
            .{
                .location = 2,
                .binding = 0,
                .format = .r8g8b8a8_unorm,
                .offset = @offsetOf(imgui.DrawVert, "col"),
            },
        };
        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        var pipeline: vk.Pipeline = undefined;
        _ = try vc.device.createGraphicsPipelines(.null_handle, (&vk.GraphicsPipelineCreateInfo{
            .stage_count = shader_stage_create_info.len,
            .p_stages = &shader_stage_create_info,
            .p_vertex_input_state = &vk.PipelineVertexInputStateCreateInfo{
                .vertex_binding_description_count = 1,
                .p_vertex_binding_descriptions = (&vk.VertexInputBindingDescription{
                    .binding = 0,
                    .stride = @sizeOf(imgui.DrawVert),
                    .input_rate = .vertex,
                })[0..1],
                .vertex_attribute_description_count = vertex_attribute_descriptions.len,
                .p_vertex_attribute_descriptions = &vertex_attribute_descriptions,
            },
            .p_input_assembly_state = &vk.PipelineInputAssemblyStateCreateInfo{
                .topology = .triangle_list,
                .primitive_restart_enable = .false,
            },
            .p_viewport_state = &vk.PipelineViewportStateCreateInfo{
                .viewport_count = 1,
                .scissor_count = 1,
            },
            .p_rasterization_state = &vk.PipelineRasterizationStateCreateInfo{
                .depth_clamp_enable = .false,
                .rasterizer_discard_enable = .false,
                .polygon_mode = .fill,
                .front_face = .counter_clockwise,
                .depth_bias_enable = .false,
                .depth_bias_constant_factor = 0.0,
                .depth_bias_clamp = 0.0,
                .depth_bias_slope_factor = 0.0,
                .line_width = 1.0,
            },
            .p_color_blend_state = &vk.PipelineColorBlendStateCreateInfo{
                .logic_op_enable = .false,
                .logic_op = .clear,
                .attachment_count = 1,
                .p_attachments = (&vk.PipelineColorBlendAttachmentState{
                    .blend_enable = .true,
                    .src_color_blend_factor = .src_alpha,
                    .dst_color_blend_factor = .one_minus_src_alpha,
                    .color_blend_op = .add,
                    .src_alpha_blend_factor = .one,
                    .dst_alpha_blend_factor = .one_minus_src_alpha,
                    .alpha_blend_op = .add,
                    .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
                })[0..1],
                .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
            },
            .p_dynamic_state = &vk.PipelineDynamicStateCreateInfo{
                .dynamic_state_count = dynamic_states.len,
                .p_dynamic_states = &dynamic_states,
            },
            .p_multisample_state = &vk.PipelineMultisampleStateCreateInfo {
                .rasterization_samples = .{ .@"1_bit" = true },
                .min_sample_shading = 1.0,
                .sample_shading_enable = .false,
                .alpha_to_coverage_enable = .false,
                .alpha_to_one_enable = .false,
            },
            .layout = pipeline_layout,
            .render_pass = .null_handle,
            .subpass = 0,
            .base_pipeline_index = 0,
            .p_next = &vk.PipelineRenderingCreateInfo{
                .view_mask = 0,
                .color_attachment_count = 1,
                .p_color_attachment_formats = (&format)[0..1],
                .depth_attachment_format = .undefined,
                .stencil_attachment_format = .undefined,
            },
        })[0..1], null, (&pipeline)[0..1]);
        try vk_helpers.setDebugName(vc.device, pipeline, "gui");
        break :blk pipeline;
    };

    const font_image = blk: {
        const tex_data = imgui.getTexDataAsAlpha8(imgui.getIO().Fonts);
        const image = try Image.create(vc, tex_data[1], .{ .transfer_dst_bit = true, .sampled_bit = true }, .r8_unorm, false, "imgui font");
        errdefer image.destroy(vc);

        const img_data = tex_data[0][0 .. tex_data[1].width * tex_data[1].height * @sizeOf(u8)];
        const staging_data = try encoder.uploadAllocator().dupe(u8, img_data);
        encoder.initializeImage(u8, encoder.upload_allocator.getBufferSlice(staging_data), image.handle, tex_data[1]);
        break :blk image;
    };

    const font_image_set = try descriptor_set_layout.allocateSet(vc, [_]vk.WriteDescriptorSet{
        .{
            .dst_set = undefined,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = (&vk.DescriptorImageInfo{
                .sampler = undefined,
                .image_view = font_image.view,
                .image_layout = .general,
            })[0..1],
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    });

    // sort of a stupid allocation strategy right now
    // create a pretty big buffer that should be good enough for most things, and ensure dear imgui doesn't want to use more at each frame
    // TODO: change this when the rest of the system becomes smart enough that this looks stupid in comparison
    var vertex_buffers: [frames_in_flight]VertexBuffer = undefined;
    for (&vertex_buffers) |*buffer| {
        buffer.* = try VertexBuffer.create(vc, std.math.maxInt(imgui.DrawIdx), "imgui vertex buffer");
    }
    var index_buffers: [frames_in_flight]IndexBuffer = undefined;
    for (&index_buffers) |*buffer| {
        buffer.* = try IndexBuffer.create(vc, std.math.maxInt(imgui.DrawIdx), "imgui index buffer");
    }

    return Self{

        .descriptor_set_layout = descriptor_set_layout,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,

        .font_sampler = font_sampler,
        .font_image = font_image,
        .font_image_set = font_image_set,

        .vertex_buffers = vertex_buffers,
        .index_buffers = index_buffers,
    };
}

pub fn destroy(self: *Self, vc: *const VulkanContext) void {
    self.descriptor_set_layout.destroy(vc);
    vc.device.destroyPipelineLayout(self.pipeline_layout, null);
    vc.device.destroyPipeline(self.pipeline, null);

    vc.device.destroySampler(self.font_sampler, null);
    self.font_image.destroy(vc);

    for (self.vertex_buffers) |buffer| buffer.destroy(vc);
    for (self.index_buffers) |buffer| buffer.destroy(vc);

    imgui.implGlfwShutdown();
    imgui.destroyContext();
}

pub fn startFrame(self: *Self) void {
    _ = self; // ensure we're initialized
    imgui.implGlfwNewFrame();
    imgui.newFrame();
}

pub fn endFrame(self: *Self, command_buffer: VulkanContext.CommandBuffer, extent: vk.Extent2D, image_view: vk.ImageView, display_image_index: usize) void {
    imgui.render();
    const draw_data = imgui.getDrawData();

    // copy all imgui vertex/index data into our one big buffer
    const vertex_buffer = self.vertex_buffers[display_image_index];
    const index_buffer = self.index_buffers[display_image_index];
    std.debug.assert(draw_data.TotalVtxCount <= vertex_buffer.len);
    std.debug.assert(draw_data.TotalIdxCount <= index_buffer.len);
    var vertex_offset: usize = 0;
    var index_offset: usize = 0;
    for (draw_data.CmdLists.Data[0..@intCast(draw_data.CmdListsCount)]) |cmd_list| {
        const vertex_count: usize = @intCast(cmd_list.*.VtxBuffer.Size);
        const index_count: usize = @intCast(cmd_list.*.IdxBuffer.Size);
        @memcpy(vertex_buffer.hostSlice()[vertex_offset..].ptr, cmd_list.*.VtxBuffer.Data[0..vertex_count]);
        @memcpy(index_buffer.hostSlice()[index_offset..].ptr, cmd_list.*.IdxBuffer.Data[0..index_count]);
        vertex_offset += vertex_count;
        index_offset += index_count;
    }

    command_buffer.beginRendering(&vk.RenderingInfo{
        .render_area = vk.Rect2D{
            .offset = vk.Offset2D{
                .x = 0.0,
                .y = 0.0,
            },
            .extent = extent,
        },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = (&vk.RenderingAttachmentInfo{
            .image_view = image_view,
            .image_layout = .general,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .uint_32 = [4]u32{ 0, 0, 0, 0 } } },
        })[0..1],
    });
    command_buffer.bindPipeline(.graphics, self.pipeline);
    command_buffer.bindVertexBuffers(0, (&vertex_buffer.handle)[0..1], (&@as(vk.DeviceSize, 0))[0..1]);
    command_buffer.bindIndexBuffer(index_buffer.handle, 0, .uint16);
    command_buffer.setViewport(0, (&vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
    })[0..1]);
    {
        const scale = [2]f32{
            2.0 / draw_data.DisplaySize.x,
            2.0 / draw_data.DisplaySize.y,
        };
        const translate = [2]f32{
            -1.0 - draw_data.DisplayPos.x * scale[0],
            -1.0 - draw_data.DisplayPos.y * scale[1],
        };
        command_buffer.pushConstants(self.pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(f32) * 4, &std.mem.toBytes(.{ scale, translate }));
    }
    command_buffer.bindDescriptorSets(.graphics, self.pipeline_layout, 0, (&self.font_image_set)[0..1], &.{});

    var global_idx_offset: u32 = 0;
    var global_vtx_offset: u32 = 0;
    for (draw_data.CmdLists.Data[0..@intCast(draw_data.CmdListsCount)]) |cmd_list| {
        for (cmd_list.*.CmdBuffer.Data[0..@intCast(cmd_list.*.CmdBuffer.Size)]) |cmd| {
            if (cmd.UserCallback) |_| @panic("todo");
            command_buffer.setScissor(0, (&vk.Rect2D{
                .offset = vk.Offset2D {
                    .x = @intFromFloat(cmd.ClipRect.x),
                    .y = @intFromFloat(cmd.ClipRect.y),
                },
                .extent = vk.Extent2D {
                    .width = @as(u32, @intFromFloat(cmd.ClipRect.z)) - @as(u32, @intFromFloat(cmd.ClipRect.x)),
                    .height = @as(u32, @intFromFloat(cmd.ClipRect.w)) - @as(u32, @intFromFloat(cmd.ClipRect.y)),
                },
            })[0..1]);
            command_buffer.drawIndexed(cmd.ElemCount, 1, global_idx_offset + cmd.IdxOffset, @intCast(global_vtx_offset + cmd.VtxOffset), 0);
        }
        global_idx_offset += @intCast(cmd_list.*.IdxBuffer.Size);
        global_vtx_offset += @intCast(cmd_list.*.VtxBuffer.Size);
    }
    command_buffer.endRendering();
}

pub const GuiDescriptorLayout = DescriptorLayout(&.{
    .{
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
        .binding_flags = .{},
    },
}, .{}, 1, "Gui");

