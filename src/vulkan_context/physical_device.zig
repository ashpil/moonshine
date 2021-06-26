const std = @import("std");
const vk = @import("vulkan");

const shared = @import("./shared.zig");
const Instance = shared.Instance;
const Device = shared.Device;
const validate = shared.validate;
const VulkanContextError = shared.VulkanContextError;
const validation_layers = shared.validation_layers;

const device_extensions = [_][*:0]const u8{ vk.extension_info.khr_swapchain.name };

pub const PhysicalDevice = struct {
    handle: vk.PhysicalDevice,
    queue_families: QueueFamilies,

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

    pub fn pick(instance: Instance, allocator: *std.mem.Allocator, surface: vk.SurfaceKHR) !PhysicalDevice {
        var device_count: u32 = 0;
        _ = try instance.enumeratePhysicalDevices(&device_count, null);

        const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
        defer allocator.free(devices);

        _ = try instance.enumeratePhysicalDevices(&device_count, devices.ptr);
        return for (devices) |device| {
            if (try PhysicalDevice.isDeviceSuitable(instance, device, allocator, surface)) {
                if (QueueFamilies.find(instance, device, allocator, surface)) |queue_families| {
                    break PhysicalDevice {
                        .handle = device,
                        .queue_families = queue_families,
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

    pub fn createLogicalDevice(self: *const PhysicalDevice, instance: Instance) !Device {
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
            },
            null,
        );
    }
};

