const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");
const Swapchain = @import("./Swapchain.zig").Swapchain;
const Window = @import("../Window.zig");

const utils = @import("./utils.zig");

const validate = @import("build_options").vk_validation;
const measure_perf = @import("build_options").vk_measure_perf;
const windowing = @import("build_options").windowing;
const Surface = if (windowing) vk.SurfaceKHR else void;

const validation_layers = [_][*:0]const u8{ "VK_LAYER_KHRONOS_validation" };

const VulkanContextError = error {
    VulkanDynLibLoadFail,
    InstanceProcAddrNotFound,
    UnavailableValidationLayers,
    UnavailableInstanceExtensions,
    UnavailableDevices,
    SurfaceCreateFail,
    UnavailableQueues,
};

const Base = struct {
    dispatch: BaseDispatch,
    pfn_get_instance_proc_addr: vk.PfnGetInstanceProcAddr,
    vulkan_lib: if (windowing) void else std.DynLib, // if no glfw, must load vulkan dynlib ourselves

    const BaseDispatch = vk.BaseWrapper(.{
        .createInstance = true,
        .enumerateInstanceLayerProperties = true,
        .enumerateInstanceExtensionProperties = true,
    });

    fn new() !Base {
        var pfn_get_instance_proc_addr: vk.PfnGetInstanceProcAddr = undefined;
        var vulkan_lib: if (windowing) void else std.DynLib = undefined;
        if (windowing) {
            pfn_get_instance_proc_addr = Window.getInstanceProcAddress;
        } else {
            const vulkan_lib_name = if (builtin.os.tag == .windows) "vulkan-1.dll" else "libvulkan.so.1";
            vulkan_lib = std.DynLib.open(vulkan_lib_name) catch std.DynLib.open("libvulkan.so") catch return VulkanContextError.VulkanDynLibLoadFail;
            pfn_get_instance_proc_addr = vulkan_lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return VulkanContextError.InstanceProcAddrNotFound;
        }
        return Base {
            .dispatch = try BaseDispatch.load(pfn_get_instance_proc_addr),
            .pfn_get_instance_proc_addr = pfn_get_instance_proc_addr,
            .vulkan_lib = vulkan_lib,
        };
    }

    fn destroy(self: Base) void {
        var self_mut = self;
        if (!windowing) self_mut.vulkan_lib.close();
    }

    fn getRequiredExtensions(allocator: std.mem.Allocator, window: if (windowing) *const Window else void) std.mem.Allocator.Error![]const [*:0]const u8 {
        const window_extensions = if (windowing) window.getRequiredInstanceExtensions() else &[_] [*:0]const u8{};
        if (validate) {
            const debug_extensions = [_][*:0]const u8{
                vk.extension_info.ext_debug_utils.name,
            };
            return std.mem.concat(allocator, [*:0]const u8, &[_][]const [*:0]const u8{ &debug_extensions, window_extensions });
        } else {
            return window_extensions;
        }
    }

    fn createInstance(self: Base, args: if (windowing) WindowingArgs else NoWindowingArgs) !Instance {
        const required_extensions = try getRequiredExtensions(args.allocator, if (windowing) args.window else {});
        defer if (validate) args.allocator.free(required_extensions);

        if (validate and !(try self.validationLayersAvailable(args.allocator))) return VulkanContextError.UnavailableValidationLayers;
        if (!try self.instanceExtensionsAvailable(args.allocator, required_extensions)) return VulkanContextError.UnavailableInstanceExtensions;

        const app_info = .{
            .p_application_name = args.app_name,
            .application_version = 0,
            .p_engine_name = "engine? i barely know 'in",
            .engine_version = 0,
            .api_version = vk.API_VERSION_1_3,
        };

        return try self.dispatch.createInstance(
            Instance,
            self.pfn_get_instance_proc_addr,
            &.{
                .p_application_info = &app_info,
                .enabled_layer_count = if (validate) validation_layers.len else 0,
                .pp_enabled_layer_names = if (validate) &validation_layers else undefined,
                .enabled_extension_count = @intCast(u32, required_extensions.len),
                .pp_enabled_extension_names = required_extensions.ptr,
                .p_next = if (validate) &debug_messenger_create_info else null,
            },
            null
        );
    }

    fn validationLayersAvailable(self: Base, allocator: std.mem.Allocator) !bool {
        const available_layers = try utils.getVkSlice(allocator, BaseDispatch.enumerateInstanceLayerProperties, .{ self.dispatch });
        defer allocator.free(available_layers);

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
        const available_extensions = try utils.getVkSlice(allocator, BaseDispatch.enumerateInstanceExtensionProperties, .{ self.dispatch, null });
        defer allocator.free(available_extensions);

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
    .enumeratePhysicalDevices = true,
    .enumerateDeviceExtensionProperties = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getDeviceProcAddr = true,
    .createDevice = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getPhysicalDeviceProperties2 = true,
};

const windowing_instance_cmds = if (windowing) vk.InstanceCommandFlags {
    .destroySurfaceKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
} else .{};

const validation_instance_cmds = if (validate) vk.InstanceCommandFlags {
    .createDebugUtilsMessengerEXT = true,
    .destroyDebugUtilsMessengerEXT = true,
} else .{};

const Instance = vk.InstanceWrapper(instance_cmds.merge(validation_instance_cmds).merge(windowing_instance_cmds));

const device_commands = vk.DeviceCommandFlags {
    .getDeviceQueue = true,
    .createImageView = true,
    .destroyDevice = true,
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

const windowing_device_commands = if (windowing) vk.DeviceCommandFlags {
    .getSwapchainImagesKHR = true,
    .createSwapchainKHR = true,
    .acquireNextImage2KHR = true,
    .queuePresentKHR = true,
    .destroySwapchainKHR = true,
} else .{};

const perf_device_commands = if (measure_perf) vk.DeviceCommandFlags {
    .cmdWriteTimestamp2 = true,
} else .{};

const validation_device_commands = if (validate) vk.DeviceCommandFlags {
    .setDebugUtilsObjectNameEXT = true,
} else .{};

const Device = vk.DeviceWrapper(blk: {@setEvalBranchQuota(10000); break :blk device_commands.merge(perf_device_commands).merge(windowing_device_commands).merge(validation_device_commands);});

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_type: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
    ) callconv(.C) vk.Bool32 {
    _ = message_type;
    _ = user_data;
    const verbose_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .verbose_bit_ext = true }).toInt();
    const info_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .info_bit_ext = true }).toInt();
    const warning_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .warning_bit_ext = true }).toInt();
    const error_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .error_bit_ext = true }).toInt();
    const color: u32 = switch (message_severity.toInt()) {
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
};

base: Base,
instance: Instance,
device: Device,

physical_device: PhysicalDevice,
surface: Surface,

debug_messenger: if (validate) vk.DebugUtilsMessengerEXT else void,

queue: vk.Queue,

const Self = @This();

const WindowingArgs = struct {
    allocator: std.mem.Allocator,
    window: *const Window,
    app_name: [*:0]const u8
};

const NoWindowingArgs = struct {
    allocator: std.mem.Allocator,
    app_name: [*:0]const u8
};

pub fn create(args: if (windowing) WindowingArgs else NoWindowingArgs) !Self {
    var base = try Base.new();
    errdefer base.destroy();

    const instance = try base.createInstance(args);
    errdefer instance.destroyInstance(null);

    const debug_messenger = if (validate) try instance.createDebugUtilsMessengerEXT(&debug_messenger_create_info, null) else undefined;
    errdefer if (validate) instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);

    const surface = if (windowing) try args.window.createSurface(instance.handle) else {};
    errdefer if (windowing) instance.destroySurfaceKHR(surface, null);

    const physical_device = try PhysicalDevice.pick(instance, args.allocator, surface);
    const device = try physical_device.createLogicalDevice(instance);
    errdefer device.destroyDevice(null);

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

pub fn destroy(self: Self) void {
    self.device.destroyDevice(null);
    if (windowing) self.instance.destroySurfaceKHR(self.surface, null);

    if (validate) self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    self.instance.destroyInstance(null);
    self.base.destroy();
}

const PhysicalDevice = struct {
    handle: vk.PhysicalDevice,
    queue_family_index: u32,
    raytracing_properties: vk.PhysicalDeviceRayTracingPipelinePropertiesKHR, // TODO: should this live somewhere else?

    const base_device_extensions = [_][*:0]const u8{
        vk.extension_info.khr_deferred_host_operations.name,
        vk.extension_info.khr_acceleration_structure.name,
        vk.extension_info.khr_ray_tracing_pipeline.name,
        vk.extension_info.khr_synchronization_2.name,
    };

    const windowing_device_extensions = [_][*:0]const u8{
        vk.extension_info.khr_swapchain.name,
    };

    const device_extensions = if (windowing) base_device_extensions ++ windowing_device_extensions else base_device_extensions;

    fn pickQueueFamily(instance: Instance, device: vk.PhysicalDevice, surface: Surface) !u32 {
        const families = utils.getVkSliceBounded(8, Instance.getPhysicalDeviceQueueFamilyProperties, .{ instance, device }).slice();

        var picked_family: ?u32 = null;
        for (families, 0..) |family, i| {
            const index = @intCast(u32, i);
            if (family.queue_flags.compute_bit and
                family.queue_flags.graphics_bit and
                if (windowing) (try instance.getPhysicalDeviceSurfaceSupportKHR(device, index, surface)) == vk.TRUE else true) picked_family = index;
        }

        if (picked_family) |index| {
            return index;
        } else return VulkanContextError.UnavailableQueues;
    }

    fn pick(instance: Instance, allocator: std.mem.Allocator, surface: Surface) !PhysicalDevice {
        const devices = (try utils.getVkSliceBounded(4, Instance.enumeratePhysicalDevices, .{ instance })).slice();

        return for (devices) |device| {
            if (try PhysicalDevice.isDeviceSuitable(instance, device, allocator, surface)) {
                if (pickQueueFamily(instance, device, surface)) |index| {

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
                        .raytracing_properties = raytracing_properties,
                    };
                } else |err| return err;
            }
        } else return VulkanContextError.UnavailableDevices;
    }

    fn isDeviceSuitable(instance: Instance, device: vk.PhysicalDevice, allocator: std.mem.Allocator, surface: Surface) !bool {
        const extensions_available = try PhysicalDevice.deviceExtensionsAvailable(instance, device, allocator);
        const surface_supported = if (windowing) try PhysicalDevice.surfaceSupported(instance, device, surface) else true;
        return extensions_available and surface_supported;
    }

    fn deviceExtensionsAvailable(instance: Instance, device: vk.PhysicalDevice, allocator: std.mem.Allocator) !bool {
        const available_extensions = try utils.getVkSlice(allocator, Instance.enumerateDeviceExtensionProperties, .{ instance, device, null });
        defer allocator.free(available_extensions);

        for (device_extensions) |extension_name| {
            const extension_found = for (available_extensions) |extension| {
                if (std.cstr.cmp(extension_name, @ptrCast([*:0]const u8, &extension.extension_name)) == 0) {
                    break true;
                }
            } else false;

            if (!extension_found) {
                // std.log.err("Couldn't find necessary extension {s}!", .{extension_name});
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
            .descriptor_binding_partially_bound = vk.TRUE,
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
                .p_next = &device_features,
            },
            null,
        );
    }
};

