const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");

const vk_helpers = @import("../engine.zig").core.vk_helpers;

const build_options = @import("build_options");
const validate = build_options.vk_validation != .ignore;
const collect_timestamps = build_options.tracy;

const root = @import("root");

const validation_layers = [_][*:0]const u8{ "VK_LAYER_KHRONOS_validation" };

pub const VulkanContextError = error {
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

    fn validationLayersAvailable(self: Base, transient: std.mem.Allocator) !bool {
        const available_layers = try self.dispatch.enumerateInstanceLayerPropertiesAlloc(transient);
        defer transient.free(available_layers);

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
        const available_extensions = try self.dispatch.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
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
fn writeMinimalStacktrace(address: usize, debug_info: *std.debug.SelfInfo, out_stream: *std.Io.Writer, tty_config: std.io.tty.Config) !void {
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
    ) callconv(.c) vk.Bool32 {
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

    var buffer: [1024]u8 = undefined;
    var out_stream = std.fs.File.stderr().writer(&buffer);
    const writer = &out_stream.interface;
    const tty_config = std.io.tty.detectConfig(std.fs.File.stderr());

    tty_config.setColor(writer, color) catch {};
    writer.print("{s}\n", .{ callback_data.?.p_message.? }) catch @panic("unable to write validation error to stderr");
    tty_config.setColor(writer, .reset) catch {};

    // write stack trace for validation error
    switch (@import("build_options").vk_validation) {
        .print => {
            if (std.debug.getSelfDebugInfo()) |debug_info| {
                writeMinimalStacktrace(@returnAddress(), debug_info, writer, tty_config) catch @panic("unable to write validation error stack trace to stderr");
            } else |_| {}
        },
        .panic => @panic("validation error encountered"),
        .ignore => unreachable,
    }

    writer.flush() catch @panic("unable to flush writer");

    return vk.FALSE;
}

const debug_messenger_create_info = vk.DebugUtilsMessengerCreateInfoEXT {
    .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true},
    .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
    .pfn_user_callback = debugCallback,
};

pub const MemoryTypes = struct {
    size: u32,
    buffer: [vk.MAX_MEMORY_TYPES]vk.MemoryPropertyFlags,

    fn slice(self: *const MemoryTypes) []const vk.MemoryPropertyFlags {
        return self.buffer[0..self.size];
    }

    pub fn create(instance: Instance, physical_device: PhysicalDevice) MemoryTypes {
        const properties = instance.getPhysicalDeviceMemoryProperties(physical_device.handle);

        var self = MemoryTypes {
            .size = properties.memory_type_count,
            .buffer = undefined,
        };

        for (properties.memory_types[0..properties.memory_type_count], self.buffer[0..self.size]) |types, *flags| {
            flags.* = types.property_flags;
        }

        return self;
    }

    pub fn find(self: MemoryTypes, type_filter: u32, required_properties: vk.MemoryPropertyFlags) !std.meta.Int(.unsigned, vk.MAX_MEMORY_TYPES) {
        return for (self.slice(), 0..) |avalable_properties, i| {
            if (type_filter & (@as(u32, 1) << @intCast(i)) != 0 and avalable_properties.contains(required_properties)) {
                break @intCast(i);
            }
        } else error.UnavailbleMemoryType;
    }
};

base: Base,
instance_dispatch: *vk.InstanceWrapper,
device_dispatch: *vk.DeviceWrapper,
instance: Instance,
device: Device,

physical_device: PhysicalDevice,

debug_messenger: if (validate) vk.DebugUtilsMessengerEXT else void,

queue: Queue,

memory_types: MemoryTypes,
timestamp_period_ns: if (collect_timestamps) f32 else void,

const Self = @This();

const QueueFamilyAcceptable = fn(vk.Instance, vk.PhysicalDevice, u32) bool;
fn returnsTrue(_: vk.Instance, _: vk.PhysicalDevice, _: u32) bool { return true; }

const base_core_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_push_descriptor.name,
};

const collect_timestamps_core_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_maintenance_9.name,
};

const core_device_extensions = if (collect_timestamps) base_core_device_extensions ++ collect_timestamps_core_device_extensions else base_core_device_extensions;

pub const VulkanRequirements = struct {
    instance_extensions: []const [*:0]const u8 = &.{},
    device_extensions: []const [*:0]const u8 = &.{},
    features: ?*const anyopaque = null,
    queueFamilyAcceptable: *const QueueFamilyAcceptable = returnsTrue,

    pub fn merge(comptime self: VulkanRequirements, comptime other: VulkanRequirements) VulkanRequirements {
        const Wrapper = struct {
            fn queueFamilyAcceptable(instance: vk.Instance, physical_device: vk.PhysicalDevice, idx: u32) bool {
                return self.queueFamilyAcceptable(instance, physical_device, idx) and other.queueFamilyAcceptable(instance, physical_device, idx);
            }
        };
        comptime var features = self.features;
        comptime while (features != null) {
            const features_base: *const vk.BaseInStructure = @alignCast(@ptrCast(features.?));
            features = features_base.p_next;
        };
        features = other.features;
        return VulkanRequirements {
            .instance_extensions = self.instance_extensions ++ other.instance_extensions,
            .device_extensions = self.device_extensions ++ other.device_extensions,
            .features = self.features,
            .queueFamilyAcceptable = Wrapper.queueFamilyAcceptable,
        };
    }
};

pub fn create(allocator: std.mem.Allocator, app_name: [*:0]const u8, requirements: VulkanRequirements) !Self {
    var base = try Base.new();
    errdefer base.destroy();

    const instance_handle = try base.createInstance(allocator, app_name, requirements.instance_extensions);
    const instance_dispatch = try allocator.create(vk.InstanceWrapper);
    instance_dispatch.* = vk.InstanceWrapper.load(instance_handle, base.pfn_get_instance_proc_addr);
    const instance = Instance.init(instance_handle, instance_dispatch);
    errdefer instance.destroyInstance(null);

    const debug_messenger = if (validate) try instance.createDebugUtilsMessengerEXT(&debug_messenger_create_info, null) else undefined;
    errdefer if (validate) instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);

    const all_device_extensions = try std.mem.concat(allocator, [*:0]const u8, &[_][]const [*:0]const u8{ &core_device_extensions, requirements.device_extensions });
    defer allocator.free(all_device_extensions);
    const physical_device = try PhysicalDevice.pick(instance, allocator, requirements.queueFamilyAcceptable, all_device_extensions);
    const device_handle = try physical_device.createLogicalDevice(instance, all_device_extensions, requirements.features);
    const device_dispatch = try allocator.create(vk.DeviceWrapper);
    device_dispatch.* = vk.DeviceWrapper.load(device_handle, instance_dispatch.dispatch.vkGetDeviceProcAddr.?);
    const device = Device.init(device_handle, device_dispatch);
    errdefer device.destroyDevice(null);

    const queue_handle = device.getDeviceQueue(physical_device.queue_family_index, 0);
    const queue = Queue.init(queue_handle, device_dispatch);

    const properties = if (collect_timestamps) blk: {
        var properties = vk.PhysicalDeviceProperties2 {
            .properties = undefined,
        };

        instance.getPhysicalDeviceProperties2(physical_device.handle, &properties);

        break :blk properties.properties;
    } else {};

    return Self {
        .base = base,
        .instance_dispatch = instance_dispatch,
        .instance = instance,
        .debug_messenger = debug_messenger,
        .device_dispatch = device_dispatch,
        .device = device,
        .physical_device = physical_device,

        .queue = queue,

        .memory_types = MemoryTypes.create(instance, physical_device),
        .timestamp_period_ns = if (collect_timestamps) properties.limits.timestamp_period else {},
    };
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

    fn pickQueueFamily(instance: Instance, transient: std.mem.Allocator, device: vk.PhysicalDevice, queueFamilyAcceptable: *const QueueFamilyAcceptable) !u32 {
        const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(device, transient);
        defer transient.free(families);

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

    fn pick(instance: Instance, transient: std.mem.Allocator, queueFamilyAcceptable: *const QueueFamilyAcceptable, extensions: []const [*:0]const u8) !PhysicalDevice {
        const devices = try instance.enumeratePhysicalDevicesAlloc(transient);
        defer transient.free(devices);

        return for (devices) |device| {
            if (try PhysicalDevice.deviceExtensionsAvailable(instance, device, transient, extensions)) {
                if (pickQueueFamily(instance, transient, device, queueFamilyAcceptable)) |index| {
                    break PhysicalDevice {
                        .handle = device,
                        .queue_family_index = index,
                    };
                } else |err| return err;
            }
        } else return VulkanContextError.UnavailableDevices;
    }

    fn deviceExtensionsAvailable(instance: Instance, device: vk.PhysicalDevice, transient: std.mem.Allocator, extensions: []const [*:0]const u8) !bool {
        const available_extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(device, null, transient);
        defer transient.free(available_extensions);

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
            .host_query_reset = if (collect_timestamps) vk.TRUE else vk.FALSE,
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

