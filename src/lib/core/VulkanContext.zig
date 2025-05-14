const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");

const vk_helpers = @import("../engine.zig").core.vk_helpers;

const validate = @import("build_options").vk_validation != .ignore;

const root = @import("root");

const validation_layers = [_][*:0]const u8{ "VK_LAYER_KHRONOS_validation" };

const VulkanContextError = error {
    VulkanDynLibLoadFail,
    InstanceProcAddrNotFound,
    UnavailableValidationLayers,
    UnavailableInstanceExtensions,
    UnavailableDevices,
    UnavailableQueues,
};

pub const Instance = vk.InstanceProxy;
pub const Device = vk.DeviceProxy;
pub const Queue = vk.QueueProxy;
pub const CommandBuffer = vk.CommandBufferProxy;

const Base = struct {
    vulkan_lib: std.DynLib,
    pfn_get_instance_proc_addr: vk.PfnGetInstanceProcAddr,
    dispatch: vk.BaseWrapper,

    fn new() !Base {
        const vulkan_lib_name = if (builtin.os.tag == .windows) "vulkan-1.dll" else "libvulkan.so.1";
        var vulkan_lib = std.DynLib.open(vulkan_lib_name) catch std.DynLib.open("libvulkan.so") catch return VulkanContextError.VulkanDynLibLoadFail;
        const pfn_get_instance_proc_addr = vulkan_lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return VulkanContextError.InstanceProcAddrNotFound;
        return Base {
            .vulkan_lib = vulkan_lib,
            .pfn_get_instance_proc_addr = pfn_get_instance_proc_addr,
            .dispatch = vk.BaseWrapper.load(pfn_get_instance_proc_addr),
        };
    }

    fn destroy(self: Base) void {
        var self_mut = self;
        self_mut.vulkan_lib.close();
    }

    fn getRequiredExtensions(allocator: std.mem.Allocator, required_extension_names: []const [*:0]const u8) std.mem.Allocator.Error![]const [*:0]const u8 {
        if (validate) {
            const debug_extensions = [_][*:0]const u8{
                vk.extensions.ext_debug_utils.name,
            };
            return std.mem.concat(allocator, [*:0]const u8, &[_][]const [*:0]const u8{ &debug_extensions, required_extension_names });
        } else {
            return allocator.dupe([*:0]const u8, required_extension_names);
        }
    }

    fn createInstance(self: Base, allocator: std.mem.Allocator, app_name: [*:0]const u8, required_extension_names: []const [*:0]const u8) !vk.Instance {
        const required_extensions = try getRequiredExtensions(allocator, required_extension_names);
        defer allocator.free(required_extensions);

        if (validate and !(try self.validationLayersAvailable(allocator))) return VulkanContextError.UnavailableValidationLayers;
        if (!try self.instanceExtensionsAvailable(allocator, required_extensions)) return VulkanContextError.UnavailableInstanceExtensions;

        const app_info = vk.ApplicationInfo {
            .p_application_name = app_name,
            .application_version = 0,
            .p_engine_name = "moonshine",
            .engine_version = 0,
            .api_version = @bitCast(vk.API_VERSION_1_4),
        };

        return try self.dispatch.createInstance(
            &.{
                .p_application_info = &app_info,
                .enabled_layer_count = if (validate) validation_layers.len else 0,
                .pp_enabled_layer_names = if (validate) &validation_layers else undefined,
                .enabled_extension_count = @as(u32, @intCast(required_extensions.len)),
                .pp_enabled_extension_names = required_extensions.ptr,
                .p_next = if (validate) &debug_messenger_create_info else null,
            },
            null
        );
    }

    fn validationLayersAvailable(self: Base, allocator: std.mem.Allocator) !bool {
        const available_layers = try vk_helpers.getVkSlice(allocator, vk.BaseWrapper.enumerateInstanceLayerProperties, .{ self.dispatch });
        defer allocator.free(available_layers);

        for (validation_layers) |layer_name| {
            const layer_found = for (available_layers) |layer_properties| {
                if (std.mem.orderZ(u8, layer_name, @ptrCast(&layer_properties.layer_name)) == .eq) {
                    break true;
                }
            } else false;

            if (!layer_found) return false;
        }
        return true;
    }

    fn instanceExtensionsAvailable(self: Base, allocator: std.mem.Allocator, extensions: []const [*:0]const u8) !bool {
        const available_extensions = try vk_helpers.getVkSlice(allocator, vk.BaseWrapper.enumerateInstanceExtensionProperties, .{ self.dispatch, null });
        defer allocator.free(available_extensions);

        for (extensions) |extension_name| {
            const layer_found = for (available_extensions) |extension_properties| {
                if (std.mem.orderZ(u8, extension_name, @ptrCast(&extension_properties.extension_name)) == .eq) {
                    break true;
                }
            } else false;

            if (!layer_found) return false;
        }
        return true;
    }
};

// writes a stacktrace that has minimal clutter:
// * strip beginning frames that do not have symbols
// * strip beginning frames that are in vk.zig
// * strip ending frames in zig setup
fn writeMinimalStacktrace(address: usize, debug_info: *std.debug.SelfInfo, out_stream: anytype, tty_config: std.io.tty.Config) !void {
    var memory = [1]usize { 0 } ** 32;
    var stack_trace: std.builtin.StackTrace = .{
        .index = undefined,
        .instruction_addresses = &memory,
    };
    std.debug.captureStackTrace(address, &stack_trace);
    stack_trace.instruction_addresses.len = stack_trace.index;

    // skip frames from start until we get something that has zig-provided
    // debug symbols, to avoid useless validation layer frames
    var skipped_frame_count: usize = 0;
    for (stack_trace.instruction_addresses) |addr| {
        if (debug_info.getModuleForAddress(addr)) |_| {
            break;
        } else |_| {}
        skipped_frame_count += 1;
    }
    stack_trace.instruction_addresses = stack_trace.instruction_addresses[skipped_frame_count..];
    stack_trace.index = stack_trace.instruction_addresses.len;

    // skip frames from start that are vk.zig frames, as
    // they are pure wrappers and can be trusted
    skipped_frame_count = 0;
    for (stack_trace.instruction_addresses) |addr| {
        if (debug_info.getModuleForAddress(addr)) |module| {
            if (module.getSymbolAtAddress(debug_info.allocator, addr)) |symbol_info| {
                if (symbol_info.source_location) |location| {
                    if (std.mem.endsWith(u8, location.file_name, "vk.zig")) {
                        skipped_frame_count += 1;
                        continue;
                    }
                }
            } else |_| {}
        } else |_| {}
        break;
    }
    stack_trace.instruction_addresses = stack_trace.instruction_addresses[skipped_frame_count..];
    stack_trace.index = stack_trace.instruction_addresses.len;

    // skip frames frames from end until we get to the our main,
    // to avoid useless zig internal frames
    skipped_frame_count = 0;
    var seen_main = false;
    for (0..stack_trace.instruction_addresses.len) |idx| {
        const addr = stack_trace.instruction_addresses[stack_trace.instruction_addresses.len - idx - 1];
        if (debug_info.getModuleForAddress(addr)) |module| {
            if (module.getSymbolAtAddress(debug_info.allocator, addr)) |symbol_info| {
                if (std.mem.eql(u8, symbol_info.name, "main")) {
                    if (seen_main) break;
                    seen_main = true;
                }
            } else |_| {}
        } else |_| {}
        skipped_frame_count += 1;
    }
    stack_trace.instruction_addresses = stack_trace.instruction_addresses[0..stack_trace.instruction_addresses.len - skipped_frame_count];
    stack_trace.index = stack_trace.instruction_addresses.len;

    try std.debug.writeStackTrace(stack_trace, out_stream, debug_info, tty_config);
}

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
    const color: std.io.tty.Color = switch (message_severity.toInt()) {
        verbose_severity => .dim,
        info_severity => .green,
        warning_severity => .yellow,
        error_severity => .red,
        else => unreachable,
    };

    const out_stream = std.io.getStdErr().writer();
    const tty_config = std.io.tty.detectConfig(std.io.getStdErr());

    tty_config.setColor(out_stream, color) catch {};
    out_stream.print("{s}\n", .{ callback_data.?.p_message.? }) catch @panic("unable to write validation error to stderr");
    tty_config.setColor(out_stream, .reset) catch {};

    // write stack trace for validation error
    switch (@import("build_options").vk_validation) {
        .print => {
            if (std.debug.getSelfDebugInfo()) |debug_info| {
                writeMinimalStacktrace(@returnAddress(), debug_info, out_stream, tty_config) catch @panic("unable to write validation error stack trace to stderr");
            } else |_| {}
        },
        .panic => @panic("validation error encountered"),
        .ignore => unreachable,
    }

    return vk.FALSE;
}

const debug_messenger_create_info = vk.DebugUtilsMessengerCreateInfoEXT {
    .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true},
    .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
    .pfn_user_callback = debugCallback,
};

base: Base,
instance_dispatch: *vk.InstanceWrapper,
device_dispatch: *vk.DeviceWrapper,
instance: Instance,
device: Device,

physical_device: PhysicalDevice,

debug_messenger: if (validate) vk.DebugUtilsMessengerEXT else void,

queue: Queue,

memory_types: std.BoundedArray(vk.MemoryPropertyFlags, vk.MAX_MEMORY_TYPES),

const Self = @This();

const QueueFamilyAcceptable = fn(vk.Instance, vk.PhysicalDevice, u32) bool;
fn returnsTrue(_: vk.Instance, _: vk.PhysicalDevice, _: u32) bool { return true; }

const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_push_descriptor.name,
};

pub fn create(allocator: std.mem.Allocator, app_name: [*:0]const u8, instance_extensions: []const [*:0]const u8, device_extensions: []const [*:0]const u8, features: ?*const anyopaque, comptime queueFamilyAcceptable: ?QueueFamilyAcceptable) !Self {
    var base = try Base.new();
    errdefer base.destroy();

    const instance_handle = try base.createInstance(allocator, app_name, instance_extensions);
    const instance_dispatch = try allocator.create(vk.InstanceWrapper);
    instance_dispatch.* = vk.InstanceWrapper.load(instance_handle, base.pfn_get_instance_proc_addr);
    const instance = Instance.init(instance_handle, instance_dispatch);
    errdefer instance.destroyInstance(null);

    const debug_messenger = if (validate) try instance.createDebugUtilsMessengerEXT(&debug_messenger_create_info, null) else undefined;
    errdefer if (validate) instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);

    const all_device_extensions = try std.mem.concat(allocator, [*:0]const u8, &[_][]const [*:0]const u8{ &required_device_extensions, device_extensions });
    defer allocator.free(all_device_extensions);
    const physical_device = try PhysicalDevice.pick(instance, allocator, if (queueFamilyAcceptable) |acc| acc else returnsTrue, all_device_extensions);
    const device_handle = try physical_device.createLogicalDevice(instance, all_device_extensions, features);
    const device_dispatch = try allocator.create(vk.DeviceWrapper);
    device_dispatch.* = vk.DeviceWrapper.load(device_handle, instance_dispatch.dispatch.vkGetDeviceProcAddr.?);
    const device = Device.init(device_handle, device_dispatch);
    errdefer device.destroyDevice(null);

    const queue_handle = device.getDeviceQueue(physical_device.queue_family_index, 0);
    const queue = Queue.init(queue_handle, device_dispatch);

    const properties = instance.getPhysicalDeviceMemoryProperties(physical_device.handle);

    var memory_types = std.BoundedArray(vk.MemoryPropertyFlags, vk.MAX_MEMORY_TYPES).init(properties.memory_type_count) catch unreachable;

    for (properties.memory_types[0..properties.memory_type_count], memory_types.slice()) |src, *dst| {
        dst.* = src.property_flags;
    }

    return Self {
        .base = base,
        .instance_dispatch = instance_dispatch,
        .instance = instance,
        .debug_messenger = debug_messenger,
        .device_dispatch = device_dispatch,
        .device = device,
        .physical_device = physical_device,

        .queue = queue,

        .memory_types = memory_types,
    };
}

pub fn findMemoryType(self: Self, type_filter: u32, required_properties: vk.MemoryPropertyFlags) !std.meta.Int(.unsigned, vk.MAX_MEMORY_TYPES) {
    return for (self.memory_types.slice(), 0..) |avalable_properties, i| {
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and avalable_properties.contains(required_properties)) {
            break @intCast(i);
        }
    } else error.UnavailbleMemoryType;
}

pub fn destroy(self: Self, allocator: std.mem.Allocator) void {
    self.device.destroyDevice(null);
    allocator.destroy(self.device_dispatch);

    if (validate) self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    self.instance.destroyInstance(null);
    allocator.destroy(self.instance_dispatch);
    self.base.destroy();
}

const PhysicalDevice = struct {
    handle: vk.PhysicalDevice,
    queue_family_index: u32,

    fn pickQueueFamily(instance: Instance, device: vk.PhysicalDevice, comptime queueFamilyAcceptable: QueueFamilyAcceptable) !u32 {
        const families = vk_helpers.getVkSliceBounded(8, Instance.getPhysicalDeviceQueueFamilyProperties, .{ instance, device }).slice();

        var picked_family: ?u32 = null;
        for (families, 0..) |family, i| {
            const index: u32 = @intCast(i);
            if (family.queue_flags.compute_bit and
                family.queue_flags.graphics_bit and
                queueFamilyAcceptable(instance.handle, device, index)) picked_family = index;
        }

        if (picked_family) |index| {
            return index;
        } else return VulkanContextError.UnavailableQueues;
    }

    fn pick(instance: Instance, allocator: std.mem.Allocator, comptime queueFamilyAcceptable: QueueFamilyAcceptable, extensions: []const [*:0]const u8) !PhysicalDevice {
        const devices = (try vk_helpers.getVkSliceBounded(4, Instance.enumeratePhysicalDevices, .{ instance })).slice();

        return for (devices) |device| {
            if (try PhysicalDevice.deviceExtensionsAvailable(instance, device, allocator, extensions)) {
                if (pickQueueFamily(instance, device, queueFamilyAcceptable)) |index| {
                    break PhysicalDevice {
                        .handle = device,
                        .queue_family_index = index,
                    };
                } else |err| return err;
            }
        } else return VulkanContextError.UnavailableDevices;
    }

    fn deviceExtensionsAvailable(instance: Instance, device: vk.PhysicalDevice, allocator: std.mem.Allocator, extensions: []const [*:0]const u8) !bool {
        const available_extensions = try vk_helpers.getVkSlice(allocator, Instance.enumerateDeviceExtensionProperties, .{ instance, device, null });
        defer allocator.free(available_extensions);

        for (extensions) |extension_name| {
            const extension_found = for (available_extensions) |extension| {
                if (std.mem.orderZ(u8, extension_name, @ptrCast(&extension.extension_name)) == .eq) {
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

    fn createLogicalDevice(self: *const PhysicalDevice, instance: Instance, extensions: []const [*:0]const u8, features: ?*const anyopaque) !vk.Device {
        const priority = [_]f32{1.0};
        const queue_create_info = [_]vk.DeviceQueueCreateInfo{
            .{
                .queue_family_index = self.queue_family_index,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            }
        };

        var vulkan_13_features = vk.PhysicalDeviceVulkan13Features {
            .p_next = @constCast(features),
            .synchronization_2 = vk.TRUE,
            .dynamic_rendering = vk.TRUE, // technically not required by core lib, but afaik since vk 1.3 requires it this can't hurt?
        };

        const vulkan_12_features = vk.PhysicalDeviceVulkan12Features {
            .p_next = &vulkan_13_features,
            .buffer_device_address = vk.TRUE,
            .scalar_block_layout = vk.TRUE,
            .shader_sampled_image_array_non_uniform_indexing = vk.TRUE,
            .runtime_descriptor_array = vk.TRUE,
            .descriptor_binding_partially_bound = vk.TRUE,
            .host_query_reset = vk.TRUE,
            .descriptor_binding_update_unused_while_pending = vk.TRUE,
        };

        return try instance.createDevice(
            self.handle,
            &.{
                .queue_create_info_count = queue_create_info.len,
                .p_queue_create_infos = &queue_create_info,
                .enabled_layer_count = if (validate) validation_layers.len else 0,
                .pp_enabled_layer_names = if (validate) &validation_layers else undefined,
                .enabled_extension_count = @as(u32, @intCast(extensions.len)),
                .pp_enabled_extension_names = extensions.ptr,
                .p_enabled_features = &.{
                    .shader_int_64 = vk.TRUE,
                },
                .p_next = &vulkan_12_features,
            },
            null,
        );
    }
};

