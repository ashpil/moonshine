const c = @import("./c.zig");
const vk = @import("vulkan");
const std = @import("std");
const Swapchain = @import("./swapchain.zig").Swapchain;

const validate = @import("builtin").mode == std.builtin.Mode.Debug;

const validation_layers = [_][*:0]const u8{ "VK_LAYER_KHRONOS_validation" };

const VulkanContextError = error {
    UnavailableValidationLayers,
    UnavailableInstanceExtensions,
    UnavailableDevices,
    SurfaceCreateFail,
    UnavailableQueues,
};

const Base = struct {
    dispatch: BaseDispatch,

    const BaseDispatch = vk.BaseWrapper(.{
        .CreateInstance,
        .EnumerateInstanceLayerProperties,
        .EnumerateInstanceExtensionProperties,
    });

    fn new() !Base {
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

    fn createInstance(self: Base, allocator: *std.mem.Allocator) !Instance {
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
    .DestroyInstance,
    .DestroySurfaceKHR,
    .EnumeratePhysicalDevices,
    .EnumerateDeviceExtensionProperties,
    .GetPhysicalDeviceSurfacePresentModesKHR,
    .GetPhysicalDeviceSurfaceFormatsKHR,
    .GetPhysicalDeviceQueueFamilyProperties,
    .GetPhysicalDeviceSurfaceSupportKHR,
    .GetDeviceProcAddr,
    .CreateDevice,
    .GetPhysicalDeviceSurfaceCapabilitiesKHR,
    .GetPhysicalDeviceMemoryProperties,
};

const debug_instance_cmds = instance_cmds ++ [_]vk.InstanceCommand {
    .CreateDebugUtilsMessengerEXT,
    .DestroyDebugUtilsMessengerEXT,
};

const Instance = vk.InstanceWrapper(if (validate) debug_instance_cmds else instance_cmds);

const Device = vk.DeviceWrapper(.{
    .GetDeviceQueue,
    .GetSwapchainImagesKHR,
    .CreateSwapchainKHR,
    .CreateImageView,
    .DestroyDevice,
    .DestroySwapchainKHR,
    .DestroyImageView,
    .CreateBuffer,
    .GetBufferMemoryRequirements,
    .AllocateMemory,
    .BindBufferMemory,
    .DestroyBuffer,
    .FreeMemory,
    .MapMemory,
    .UnmapMemory,
    .CreateCommandPool,
    .DestroyCommandPool,
    .AllocateCommandBuffers,
    .FreeCommandBuffers,
    .BeginCommandBuffer,
    .CmdCopyBuffer,
    .EndCommandBuffer,
    .QueueSubmit,
    .QueueWaitIdle,
    .CreateRayTracingPipelinesKHR,
    .DestroyPipeline,
    .CreatePipelineLayout,
    .DestroyPipelineLayout,
    .CreateShaderModule,
    .DestroyShaderModule,
    .CreateDescriptorSetLayout,
    .DestroyDescriptorSetLayout,
    .CmdBindPipeline,
    .CmdBindDescriptorSets,
    .CmdBuildAccelerationStructuresKHR,
    .ResetCommandPool,
    .GetBufferDeviceAddress,
    .DestroyAccelerationStructureKHR,
    .CreateAccelerationStructureKHR,
    .GetAccelerationStructureBuildSizesKHR,
    .GetAccelerationStructureDeviceAddressKHR,
    .AcquireNextImageKHR,
    .CreateSemaphore,
    .QueuePresentKHR,
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

const debug_messenger_create_info = vk.DebugUtilsMessengerCreateInfoEXT {
    .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true},
    .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
    .pfn_user_callback = debugCallback,
    .p_user_data = null,
    .flags = .{},
};

fn createSurface(instance: Instance, window: *c.GLFWwindow) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    if (c.glfwCreateWindowSurface(instance.handle, window, null, &surface) != vk.Result.success) return VulkanContextError.SurfaceCreateFail;
    return surface;
}

base: Base,
instance: Instance,
device: Device,

physical_device: PhysicalDevice,
surface: vk.SurfaceKHR,

debug_messenger: if (validate) vk.DebugUtilsMessengerEXT else void,

const Self = @This();

pub fn create(allocator: *std.mem.Allocator, window: *c.GLFWwindow) !Self {
    const base = try Base.new();

    const instance = try base.createInstance(allocator);
    errdefer instance.destroyInstance(null);

    const debug_messenger = if (validate) try instance.createDebugUtilsMessengerEXT(debug_messenger_create_info, null) else undefined;
    errdefer if (validate) instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);

    const surface = try createSurface(instance, window);
    errdefer instance.destroySurfaceKHR(surface, null);

    const physical_device = try PhysicalDevice.pick(instance, allocator, surface);
    const device = try physical_device.createLogicalDevice(instance);
    errdefer device.destroyDevice(null);

    return Self {
        .base = base,
        .instance = instance,
        .debug_messenger = debug_messenger,
        .surface = surface,
        .device = device,
        .physical_device = physical_device,
    };
}

pub fn destroy(self: *Self) void {
    self.device.destroyDevice(null);
    self.instance.destroySurfaceKHR(self.surface, null);

    if (validate) self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    self.instance.destroyInstance(null);
}

const device_extensions = [_][*:0]const u8{
    vk.extension_info.khr_swapchain.name,
    vk.extension_info.khr_deferred_host_operations.name,
    vk.extension_info.khr_acceleration_structure.name,
    vk.extension_info.khr_ray_tracing_pipeline.name,
};

const PhysicalDevice = struct {
    handle: vk.PhysicalDevice,
    queue_families: QueueFamilies,
    mem_properties: vk.PhysicalDeviceMemoryProperties,

    const QueueFamilies = struct {
        compute: u32,
        present: u32,

        fn find(instance: Instance, device: vk.PhysicalDevice, allocator: *std.mem.Allocator, surface: vk.SurfaceKHR) !QueueFamilies {
            var compute: ?u32 = null;
            var present: ?u32 = null;

            var family_count: u32 = 0;
            instance.getPhysicalDeviceQueueFamilyProperties(device, &family_count, null);

            const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
            defer allocator.free(families);

            instance.getPhysicalDeviceQueueFamilyProperties(device, &family_count, families.ptr);

            return for (families) |family, i| {
                const index = @intCast(u32, i);
                if (compute == null and family.queue_flags.compute_bit) compute = index;
                if (present == null and ((try instance.getPhysicalDeviceSurfaceSupportKHR(device, index, surface)) == vk.TRUE)) present = index;

                if (compute != null and present != null) break QueueFamilies {
                    .compute = compute.?,
                    .present = present.?,
                };
            } else VulkanContextError.UnavailableQueues;
        }

        pub fn isExclusive(self: *const QueueFamilies) bool {
            return self.compute == self.present;
        }
    };

    fn pick(instance: Instance, allocator: *std.mem.Allocator, surface: vk.SurfaceKHR) !PhysicalDevice {
        var device_count: u32 = 0;
        _ = try instance.enumeratePhysicalDevices(&device_count, null);

        const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
        defer allocator.free(devices);

        _ = try instance.enumeratePhysicalDevices(&device_count, devices.ptr);
        return for (devices) |device| {
            if (try PhysicalDevice.isDeviceSuitable(instance, device, allocator, surface)) {
                if (QueueFamilies.find(instance, device, allocator, surface)) |queue_families| {
                    const mem_properties = instance.getPhysicalDeviceMemoryProperties(device);
                    break PhysicalDevice {
                        .handle = device,
                        .queue_families = queue_families,
                        .mem_properties = mem_properties,
                    };
                } else |err| return err;
            }
        } else return VulkanContextError.UnavailableDevices;
    }

    fn isDeviceSuitable(instance: Instance, device: vk.PhysicalDevice, allocator: *std.mem.Allocator, surface: vk.SurfaceKHR) !bool {
        const extensions_available = try PhysicalDevice.deviceExtensionsAvailable(instance, device, allocator);
        const surface_supported = try PhysicalDevice.surfaceSupported(instance, device, surface);
        return extensions_available and surface_supported;
    }

    fn deviceExtensionsAvailable(instance: Instance, device: vk.PhysicalDevice, allocator: *std.mem.Allocator) !bool {
        var extension_count: u32 = 0;
        _ = try instance.enumerateDeviceExtensionProperties(device, null, &extension_count, null);

        const available_extensions = try allocator.alloc(vk.ExtensionProperties, extension_count);
        defer allocator.free(available_extensions);

        _ = try instance.enumerateDeviceExtensionProperties(device, null, &extension_count, available_extensions.ptr);

        for (device_extensions) |extension_name| {
            const extension_found = for (available_extensions) |extension| {
                if (std.cstr.cmp(extension_name, @ptrCast([*:0]const u8, &extension.extension_name)) == 0) {
                    break true;
                }
            } else false;

            if (!extension_found) return false;
        }
        return true;
    }

    fn surfaceSupported(instance: Instance, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
        var present_mode_count: u32 = 0;
        _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null);

        var format_count: u32 = 0;
        _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);

        return present_mode_count != 0 and format_count != 0;
    }

    fn createLogicalDevice(self: *const PhysicalDevice, instance: Instance) !Device {
        const priority = [_]f32{1.0};
        const queue_create_infos = if (self.queue_families.compute == self.queue_families.present) (
            &[_]vk.DeviceQueueCreateInfo{
                .{
                    .queue_family_index = self.queue_families.compute,
                    .queue_count = 1,
                    .p_queue_priorities = &priority,
                    .flags = .{},
                }
            }
        ) else (
            &[_]vk.DeviceQueueCreateInfo{
                .{
                    .queue_family_index = self.queue_families.compute,
                    .queue_count = 1,
                    .p_queue_priorities = &priority,
                    .flags = .{},
                },
                .{
                    .queue_family_index = self.queue_families.present,
                    .queue_count = 1,
                    .p_queue_priorities = &priority,
                    .flags = .{},
                }
            }
        );
        
        var accel_struct_features = vk.PhysicalDeviceAccelerationStructureFeaturesKHR {
            .acceleration_structure = vk.TRUE,
        };

        var ray_tracing_pipeline_features = vk.PhysicalDeviceRayTracingPipelineFeaturesKHR {
            .p_next = &accel_struct_features,
            .ray_tracing_pipeline = vk.TRUE,
        };

        const device_features = vk.PhysicalDeviceVulkan12Features {
            .p_next = &ray_tracing_pipeline_features,
            .buffer_device_address = vk.TRUE,
        };

        return try instance.createDevice(
            Device,
            instance.dispatch.vkGetDeviceProcAddr,
            self.handle,
            .{
                .queue_create_info_count = @intCast(u32, queue_create_infos.len),
                .p_queue_create_infos = queue_create_infos.ptr,
                .enabled_layer_count = if (validate) validation_layers.len else 0,
                .pp_enabled_layer_names = if (validate) &validation_layers else undefined,
                .enabled_extension_count = device_extensions.len,
                .pp_enabled_extension_names = &device_extensions,
                .p_enabled_features = null,
                .flags = .{},
                .p_next = &device_features,
            },
            null,
        );
    }
};

