const std = @import("std");
const vk = @import("vulkan");
const c = @import("../c.zig");

pub const validate = @import("builtin").mode == std.builtin.Mode.Debug;

pub const validation_layers = [_][*:0]const u8{ "VK_LAYER_KHRONOS_validation" };

pub const VulkanContextError = error {
    UnavailableValidationLayers,
    UnavailableInstanceExtensions,
    UnavailableDevices,
    SurfaceCreateFail,
    UnavailableQueues,
};

pub const Base = struct {
    dispatch: BaseDispatch,

    const BaseDispatch = vk.BaseWrapper([_]vk.BaseCommand {
        .create_instance,
        .enumerate_instance_layer_properties,
        .enumerate_instance_extension_properties,
    });

    pub fn new() !Base {
        return Base {
            .dispatch = try BaseDispatch.load(c.glfwGetInstanceProcAddress),
        };
    }

    fn getRequiredExtensionsType() type {
        return if (validate) (std.mem.Allocator.Error![]const [*:0]const u8) else []const [*:0]const u8;
    }

    fn getRequiredExtensions(allocator: *std.mem.Allocator) getRequiredExtensionsType() {
        var glfw_extension_count: u32 = 0;
        const glfw_extensions = @ptrCast([*]const [*:0]const u8, c.glfwGetRequiredInstanceExtensions(&glfw_extension_count))[0..glfw_extension_count];
        if (validate) {
            const debug_extensions = [_][*:0]const u8{
                vk.extension_info.ext_debug_utils.name,
            };
            return std.mem.concat(allocator, [*:0]const u8, &[_][]const [*:0]const u8{ &debug_extensions, glfw_extensions });
        } else {
            return glfw_extensions;
        }
    }

    pub fn createInstance(self: Base, allocator: *std.mem.Allocator) !Instance {
        const required_extensions = if (validate) try getRequiredExtensions(allocator) else getRequiredExtensions(allocator);
        defer if (validate) allocator.free(required_extensions);

        if (validate and !(try self.validationLayersAvailable(allocator))) return VulkanContextError.UnavailableValidationLayers;
        if (!try self.instanceExtensionsAvailable(allocator, required_extensions)) return VulkanContextError.UnavailableInstanceExtensions;

        const app_info = .{
            .p_application_name = "Chess RTX",
            .application_version = 0,
            .p_engine_name = "engine? i barely know 'in",
            .engine_version = 0,
            .api_version = vk.API_VERSION_1_2,
        };

        return try self.dispatch.createInstance(
            Instance,
            c.glfwGetInstanceProcAddress,
            .{
                .p_application_info = &app_info,
                .enabled_layer_count = if (validate) validation_layers.len else 0,
                .pp_enabled_layer_names = if (validate) &validation_layers else undefined,
                .enabled_extension_count = @intCast(u32, required_extensions.len),
                .pp_enabled_extension_names = required_extensions.ptr,
                .flags = .{},
                .p_next = if (validate) &debug_messenger_create_info else null,
            },
            null
        );
    }

    fn validationLayersAvailable(self: Base, allocator: *std.mem.Allocator) !bool {
        var layer_count: u32 = 0;
        _ = try self.dispatch.enumerateInstanceLayerProperties(&layer_count, null);

        const available_layers = try allocator.alloc(vk.LayerProperties, layer_count);
        defer allocator.free(available_layers);
        _ = try self.dispatch.enumerateInstanceLayerProperties(&layer_count, available_layers.ptr);
        for (validation_layers) |layer_name| {
            const layer_found = for (available_layers) |layer_properties| {
                if (std.cstr.cmp(layer_name, @ptrCast([*:0]const u8, &layer_properties.layer_name)) == 0) {
                    break true;
                }
            } else false;

            if (!layer_found) return false;
        }
        return true;
    }

    fn instanceExtensionsAvailable(self: Base, allocator: *std.mem.Allocator, extensions: []const [*:0]const u8) !bool {
        var extension_count: u32 = 0;
        _ = try self.dispatch.enumerateInstanceExtensionProperties(null, &extension_count, null);

        const available_extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
        defer allocator.free(available_extensions);
        _ = try self.dispatch.enumerateInstanceExtensionProperties(null, &extension_count, available_extensions.ptr);
        for (extensions) |extension_name| {
            const layer_found = for (available_extensions) |extension_properties| {
                if (std.cstr.cmp(extension_name, @ptrCast([*:0]const u8, &extension_properties.extension_name)) == 0) {
                    break true;
                }
            } else false;

            if (!layer_found) return false;
        }
        return true;
    }
};

const instance_cmds = [_]vk.InstanceCommand {
    .destroy_instance,
    .destroy_surface_khr,
    .enumerate_physical_devices,
    .enumerate_device_extension_properties,
    .get_physical_device_surface_present_modes_khr,
    .get_physical_device_surface_formats_khr,
    .get_physical_device_queue_family_properties,
    .get_physical_device_surface_support_khr,
    .get_device_proc_addr,
    .create_device,
    .get_physical_device_surface_capabilities_khr,
};

const debug_instance_cmds = instance_cmds ++ [_]vk.InstanceCommand {
    .create_debug_utils_messenger_ext,
    .destroy_debug_utils_messenger_ext,
};

pub const Instance = vk.InstanceWrapper(if (validate) debug_instance_cmds else instance_cmds);

pub const Device = vk.DeviceWrapper(&[_]vk.DeviceCommand {
    .get_device_queue,
    .get_swapchain_images_khr,
    .create_swapchain_khr,
    .create_image_view,
    .destroy_device,
    .destroy_swapchain_khr,
    .destroy_image_view,
});

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
    message_type: vk.DebugUtilsMessageTypeFlagsEXT.IntType,
    callback_data: *const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: *c_void,
    ) callconv(.C) vk.Bool32 {
    _ = message_type;
    _ = user_data;
    const verbose_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .verbose_bit_ext = true }).toInt();
    const info_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .info_bit_ext = true }).toInt();
    const warning_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .warning_bit_ext = true }).toInt();
    const error_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .error_bit_ext = true }).toInt();
    const color: u32 = switch (message_severity) {
        verbose_severity => 37,
        info_severity => 32,
        warning_severity => 33,
        error_severity => 31,
        else => unreachable,
    };
    std.debug.print("\x1b[{}m{s}\x1b[0m\n", .{ color, callback_data.p_message });
    return 0;
}

pub const debug_messenger_create_info = vk.DebugUtilsMessengerCreateInfoEXT {
    .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true},
    .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
    .pfn_user_callback = debugCallback,
    .p_user_data = null,
    .flags = .{},
};

