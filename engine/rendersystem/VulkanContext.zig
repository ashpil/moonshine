const vk = @import("vulkan");
const std = @import("std");
const Swapchain = @import("./Swapchain.zig").Swapchain;
const Window = @import("../Window.zig");

const validate = @import("build_options").vk_enable_validation;
const measure_perf = @import("build_options").vk_measure_perf;

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
        .createInstance = true,
        .enumerateInstanceLayerProperties = true,
        .enumerateInstanceExtensionProperties = true,
    });

    fn new() !Base {
        return Base {
            .dispatch = try BaseDispatch.load(Window.getInstanceProcAddress),
        };
    }

    fn getRequiredExtensionsType() type {
        return if (validate) (std.mem.Allocator.Error![]const [*:0]const u8) else []const [*:0]const u8;
    }

    fn getRequiredExtensions(allocator: std.mem.Allocator, window: *const Window) getRequiredExtensionsType() {
        const window_extensions = window.getRequiredInstanceExtensions();
        if (validate) {
            const debug_extensions = [_][*:0]const u8{
                vk.extension_info.ext_debug_utils.name,
            };
            return std.mem.concat(allocator, [*:0]const u8, &[_][]const [*:0]const u8{ &debug_extensions, window_extensions });
        } else {
            return window_extensions;
        }
    }

    fn createInstance(self: Base, allocator: std.mem.Allocator, window: *const Window, app_name: [*:0]const u8) !Instance {
        const required_extensions = if (validate) try getRequiredExtensions(allocator, window) else getRequiredExtensions(allocator, window);
        defer if (validate) allocator.free(required_extensions);

        if (validate and !(try self.validationLayersAvailable(allocator))) return VulkanContextError.UnavailableValidationLayers;
        if (!try self.instanceExtensionsAvailable(allocator, required_extensions)) return VulkanContextError.UnavailableInstanceExtensions;

        const app_info = .{
            .p_application_name = app_name,
            .application_version = 0,
            .p_engine_name = "engine? i barely know 'in",
            .engine_version = 0,
            .api_version = vk.API_VERSION_1_3,
        };

        return try self.dispatch.createInstance(
            Instance,
            Window.getInstanceProcAddress,
            &.{
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

    fn validationLayersAvailable(self: Base, allocator: std.mem.Allocator) !bool {
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

    fn instanceExtensionsAvailable(self: Base, allocator: std.mem.Allocator, extensions: []const [*:0]const u8) !bool {
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

const instance_cmds = vk.InstanceCommandFlags {
    .destroyInstance = true,
    .destroySurfaceKHR = true,
    .enumeratePhysicalDevices = true,
    .enumerateDeviceExtensionProperties = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getDeviceProcAddr = true,
    .createDevice = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getPhysicalDeviceProperties2 = true,
};

const validation_instance_cmds = vk.InstanceCommandFlags {
    .createDebugUtilsMessengerEXT = true,
    .destroyDebugUtilsMessengerEXT = true,
};

const Instance = vk.InstanceWrapper(if (validate) instance_cmds.merge(validation_instance_cmds) else instance_cmds);

const device_commands = vk.DeviceCommandFlags {
    .getDeviceQueue = true,
    .getSwapchainImagesKHR = true,
    .createSwapchainKHR = true,
    .createImageView = true,
    .destroyDevice = true,
    .destroySwapchainKHR = true,
    .destroyImageView = true,
    .createBuffer = true,
    .getBufferMemoryRequirements = true,
    .allocateMemory = true,
    .bindBufferMemory = true,
    .destroyBuffer = true,
    .freeMemory = true,
    .mapMemory = true,
    .unmapMemory = true,
    .createCommandPool = true,
    .destroyCommandPool = true,
    .allocateCommandBuffers = true,
    .freeCommandBuffers = true,
    .beginCommandBuffer = true,
    .cmdCopyBuffer = true,
    .endCommandBuffer = true,
    .queueWaitIdle = true,
    .createRayTracingPipelinesKHR = true,
    .destroyPipeline = true,
    .createPipelineLayout = true,
    .destroyPipelineLayout = true,
    .createShaderModule = true,
    .destroyShaderModule = true,
    .createDescriptorSetLayout = true,
    .destroyDescriptorSetLayout = true,
    .cmdBindPipeline = true,
    .cmdBindDescriptorSets = true,
    .cmdBuildAccelerationStructuresKHR = true,
    .resetCommandPool = true,
    .getBufferDeviceAddress = true,
    .destroyAccelerationStructureKHR = true,
    .createAccelerationStructureKHR = true,
    .getAccelerationStructureBuildSizesKHR = true,
    .getAccelerationStructureDeviceAddressKHR = true,
    .createSemaphore = true,
    .queuePresentKHR = true,
    .destroySemaphore = true,
    .allocateDescriptorSets = true,
    .createDescriptorPool = true,
    .destroyDescriptorPool = true,
    .updateDescriptorSets = true,
    .createImage = true,
    .destroyImage = true,
    .getImageMemoryRequirements = true,
    .bindImageMemory = true,
    .getRayTracingShaderGroupHandlesKHR = true,
    .cmdTraceRaysKHR = true,
    .cmdPipelineBarrier2 = true,
    .cmdBlitImage = true,
    .deviceWaitIdle = true,
    .createFence = true,
    .destroyFence = true,
    .waitForFences = true,
    .resetFences = true,
    .queueSubmit2 = true,
    .acquireNextImage2KHR = true,
    .cmdPushConstants = true,
    .cmdCopyBufferToImage = true,
    .createSampler = true,
    .destroySampler = true,
    .createQueryPool = true,
    .cmdWriteAccelerationStructuresPropertiesKHR = true,
    .resetQueryPool = true,
    .getQueryPoolResults = true,
    .destroyQueryPool = true,
    .cmdCopyAccelerationStructureKHR = true,
    .cmdCopyImageToBuffer = true,
    .cmdUpdateBuffer = true,
};

const perf_device_commands = vk.DeviceCommandFlags {
    .cmdWriteTimestamp2 = true,
};

const Device = vk.DeviceWrapper(if (measure_perf) perf_device_commands.merge(device_commands) else device_commands);

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
    message_type: vk.DebugUtilsMessageTypeFlagsEXT.IntType,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
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
    std.debug.print("\x1b[{}m{s}\x1b[0m\n", .{ color, callback_data.?.p_message });
    return 0;
}

const debug_messenger_create_info = vk.DebugUtilsMessengerCreateInfoEXT {
    .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true},
    .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
    .pfn_user_callback = debugCallback,
    .p_user_data = null,
    .flags = .{},
};

base: Base,
instance: Instance,
device: Device,

physical_device: PhysicalDevice,
surface: vk.SurfaceKHR,

debug_messenger: if (validate) vk.DebugUtilsMessengerEXT else void,

queue: vk.Queue,

const Self = @This();

pub fn create(allocator: std.mem.Allocator, window: *const Window, app_name: [*:0]const u8) !Self {
    const base = try Base.new();

    const instance = try base.createInstance(allocator, window, app_name);
    errdefer instance.destroyInstance(null);

    const debug_messenger = if (validate) try instance.createDebugUtilsMessengerEXT(&debug_messenger_create_info, null) else undefined;
    errdefer if (validate) instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);

    const surface = try window.createSurface(instance.handle);
    errdefer instance.destroySurfaceKHR(surface, null);

    const physical_device = try PhysicalDevice.pick(instance, allocator, surface);
    const device = try physical_device.createLogicalDevice(instance);
    errdefer device.destroyDevice(null);

    // not sure what best abstraction for queues is yet
    const queue = device.getDeviceQueue(physical_device.queue_family_index, 0);

    return Self {
        .base = base,
        .instance = instance,
        .debug_messenger = debug_messenger,
        .surface = surface,
        .device = device,
        .physical_device = physical_device,

        .queue = queue,
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
    vk.extension_info.khr_synchronization_2.name,
};

const PhysicalDevice = struct {
    handle: vk.PhysicalDevice,
    queue_family_index: u32,
    properties: vk.PhysicalDeviceProperties,
    mem_properties: vk.PhysicalDeviceMemoryProperties,
    raytracing_properties: vk.PhysicalDeviceRayTracingPipelinePropertiesKHR,

    fn pickQueueFamily(instance: Instance, device: vk.PhysicalDevice, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !u32 {
        var family_count: u32 = 0;
        instance.getPhysicalDeviceQueueFamilyProperties(device, &family_count, null);

        const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
        defer allocator.free(families);
        instance.getPhysicalDeviceQueueFamilyProperties(device, &family_count, families.ptr);

        var picked_family: ?u32 = null;
        for (families) |family, i| {
            const index = @intCast(u32, i);
            if (family.queue_flags.compute_bit and
                family.queue_flags.graphics_bit and
                (try instance.getPhysicalDeviceSurfaceSupportKHR(device, index, surface)) == vk.TRUE) picked_family = index;
        }

        if (picked_family) |index| {
            return index;
        } else return VulkanContextError.UnavailableQueues;
    }

    fn pick(instance: Instance, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !PhysicalDevice {
        var device_count: u32 = 0;
        _ = try instance.enumeratePhysicalDevices(&device_count, null);

        const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
        defer allocator.free(devices);

        _ = try instance.enumeratePhysicalDevices(&device_count, devices.ptr);
        return for (devices) |device| {
            if (try PhysicalDevice.isDeviceSuitable(instance, device, allocator, surface)) {
                if (pickQueueFamily(instance, device, allocator, surface)) |index| {
                    const mem_properties = instance.getPhysicalDeviceMemoryProperties(device);

                    var raytracing_properties: vk.PhysicalDeviceRayTracingPipelinePropertiesKHR = undefined;
                    raytracing_properties.s_type = .physical_device_ray_tracing_pipeline_properties_khr;
                    raytracing_properties.p_next = null;

                    var properties2 = vk.PhysicalDeviceProperties2 {
                        .properties = undefined,
                        .p_next = &raytracing_properties,
                    };

                    instance.getPhysicalDeviceProperties2(device, &properties2);

                    break PhysicalDevice {
                        .handle = device,
                        .queue_family_index = index,
                        .properties = properties2.properties,
                        .mem_properties = mem_properties,
                        .raytracing_properties = raytracing_properties,
                    };
                } else |err| return err;
            }
        } else return VulkanContextError.UnavailableDevices;
    }

    fn isDeviceSuitable(instance: Instance, device: vk.PhysicalDevice, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !bool {
        const extensions_available = try PhysicalDevice.deviceExtensionsAvailable(instance, device, allocator);
        const surface_supported = try PhysicalDevice.surfaceSupported(instance, device, surface);
        return extensions_available and surface_supported;
    }

    fn deviceExtensionsAvailable(instance: Instance, device: vk.PhysicalDevice, allocator: std.mem.Allocator) !bool {
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

            if (!extension_found) {
                std.log.err("Couldn't find necessary extension {s}!", .{extension_name});
                return false;
            }
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
        const queue_create_info = [_]vk.DeviceQueueCreateInfo{
            .{
                .queue_family_index = self.queue_family_index,
                .queue_count = 1,
                .p_queue_priorities = &priority,
                .flags = .{},
            }
        };

        var sync2_features = vk.PhysicalDeviceSynchronization2FeaturesKHR {
            .synchronization_2 = vk.TRUE,
        };
        
        var accel_struct_features = vk.PhysicalDeviceAccelerationStructureFeaturesKHR {
            .acceleration_structure = vk.TRUE,
            .p_next = &sync2_features,
        };

        var ray_tracing_pipeline_features = vk.PhysicalDeviceRayTracingPipelineFeaturesKHR {
            .p_next = &accel_struct_features,
            .ray_tracing_pipeline = vk.TRUE,
        };

        const device_features = vk.PhysicalDeviceVulkan12Features {
            .p_next = &ray_tracing_pipeline_features,
            .buffer_device_address = vk.TRUE,
            .scalar_block_layout = vk.TRUE,
            .shader_sampled_image_array_non_uniform_indexing = vk.TRUE,
            .runtime_descriptor_array = vk.TRUE,
            .host_query_reset = vk.TRUE,
        };

        return try instance.createDevice(
            Device,
            instance.dispatch.vkGetDeviceProcAddr,
            self.handle,
            &.{
                .queue_create_info_count = queue_create_info.len,
                .p_queue_create_infos = &queue_create_info,
                .enabled_layer_count = if (validate) validation_layers.len else 0,
                .pp_enabled_layer_names = if (validate) &validation_layers else undefined,
                .enabled_extension_count = device_extensions.len,
                .pp_enabled_extension_names = &device_extensions,
                .p_enabled_features = &.{
                    .shader_int_64 = vk.TRUE,
                },
                .flags = .{},
                .p_next = &device_features,
            },
            null,
        );
    }
};

