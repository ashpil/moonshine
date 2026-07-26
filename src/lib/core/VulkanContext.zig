const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");

const vk_helpers = @import("../engine.zig").core.vk_helpers;

const validate = @import("build_options").vk_validation != .ignore;

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

const DynLib = if (builtin.os.tag == .windows) struct {
    handle: std.os.windows.HMODULE,

    fn open(path: [:0]const u8) !DynLib {
        const handle = LoadLibraryA(path.ptr) orelse return error.FileNotFound;
        return .{ .handle = handle };
    }

    fn close(self: *DynLib) void {
        std.debug.assert(FreeLibrary(self.handle).toBool());
    }

    fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        const proc = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(@as(*const anyopaque, @ptrCast(proc)));
    }

    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?std.os.windows.HMODULE;
    extern "kernel32" fn GetProcAddress(hModule: std.os.windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const fn () callconv(.winapi) isize;
    extern "kernel32" fn FreeLibrary(hModule: std.os.windows.HMODULE) callconv(.winapi) std.os.windows.BOOL;
} else std.DynLib;

const Base = struct {
    vulkan_lib: DynLib,
    pfn_get_instance_proc_addr: vk.PfnGetInstanceProcAddr,
    dispatch: vk.BaseWrapper,

    fn new() !Base {
        const vulkan_lib_name = if (builtin.os.tag == .windows) "vulkan-1.dll" else "libvulkan.so.1";
        const vulkan_lib_alt_name = if (builtin.os.tag == .windows) "vulkan.dll" else "libvulkan.so";
        var vulkan_lib = DynLib.open(vulkan_lib_name) catch DynLib.open(vulkan_lib_alt_name) catch return VulkanContextError.VulkanDynLibLoadFail;
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

        const debug_messenger_create_info = vk.DebugUtilsMessengerCreateInfoEXT {
            .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true},
            .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
            .pfn_user_callback = debugCallbackValidation,
        };

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
fn writeMinimalStacktrace(first_address: usize, terminal: std.Io.Terminal) void {
    const io = std.Options.debug_io;
    const gpa = std.debug.getDebugInfoAllocator();
    const self_info = std.debug.getSelfDebugInfo() catch {
        std.debug.writeCurrentStackTrace(.{ .allow_unsafe_unwind = true }, terminal) catch {};
        return;
    };

    var addr_buf: [32]usize = undefined;
    const st = std.debug.captureCurrentStackTrace(.{ .first_address = first_address, .allow_unsafe_unwind = true }, &addr_buf);

    if (st.return_addresses.len == 0) {
        std.debug.writeCurrentStackTrace(.{ .allow_unsafe_unwind = true }, terminal) catch {};
        return;
    }

    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    defer symbols.deinit(gpa);

    // skip frames from start:
    // * frames without source locations (validation layer, etc.)
    // * vk.zig frames (pure wrappers)
    var skip_start: usize = 0;
    for (st.return_addresses) |addr| {
        symbols.clearRetainingCapacity();
        self_info.getSymbols(io, gpa, gpa, addr, false, &symbols) catch {
            skip_start += 1;
            continue;
        };
        const location = if (symbols.items.len > 0) symbols.items[0].source_location else null;
        if (location == null) {
            skip_start += 1;
            continue;
        }
        if (std.mem.endsWith(u8, location.?.file_name, "vk.zig")) {
            skip_start += 1;
            continue;
        }
        break;
    }

    // skip frames from end until we get to our main,
    // to avoid useless zig internal frames
    var skip_end: usize = 0;
    var i = st.return_addresses.len;
    while (i > skip_start) {
        i -= 1;
        const addr = st.return_addresses[i];
        symbols.clearRetainingCapacity();
        self_info.getSymbols(io, gpa, gpa, addr, false, &symbols) catch {
            skip_end += 1;
            continue;
        };
        if (symbols.items.len > 0) {
            if (symbols.items[0].name) |name| {
                if (std.mem.eql(u8, name, "main")) break;
            }
        }
        skip_end += 1;
    }

    const end = st.return_addresses.len - skip_end;
    if (skip_start >= end) {
        std.debug.writeCurrentStackTrace(.{ .allow_unsafe_unwind = true }, terminal) catch {};
        return;
    }

    const filtered: std.debug.StackTrace = .{
        .return_addresses = st.return_addresses[skip_start..end],
        .skipped = .none,
    };
    std.debug.writeStackTrace(&filtered, terminal) catch {};
}

const DeviceAddressBindingTracker = struct {
    const BindingEvent = struct {
        range: BoundRange,
        internal: bool,
        object_type: vk.ObjectType,
        object_name: ?[]const u8,
        type: EventType,
    };

    const BoundRange = packed struct {
        base: vk.DeviceAddress,
        size: vk.DeviceSize,
    };

    const EventType = enum {
        bind,
        unbind,
    };

    const Bindings = std.ArrayListUnmanaged(BindingEvent);

    bindings: Bindings = .empty,

    fn destroy(self: *DeviceAddressBindingTracker, allocator: std.mem.Allocator) void {
        for (self.bindings.items) |binding| {
            if (binding.object_name) |name| allocator.free(name);
        }
        self.bindings.deinit(allocator);
    }

    fn append(self: *DeviceAddressBindingTracker, allocator: std.mem.Allocator, binding: BindingEvent) std.mem.Allocator.Error!void {
        try self.bindings.append(allocator, binding);
    }
};


const DebugCallbackUserData = struct {
    allocator: std.mem.Allocator,
    device_address_binding_tracker: DeviceAddressBindingTracker,

    fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*DebugCallbackUserData {
        const result = try allocator.create(DebugCallbackUserData);
        result.* = DebugCallbackUserData {
            .allocator = allocator,
            .device_address_binding_tracker = DeviceAddressBindingTracker {},
        };
        return result;
    }

    fn destroy(self: *DebugCallbackUserData) void {
        const allocator = self.allocator;
        self.device_address_binding_tracker.destroy(allocator);
        allocator.destroy(self);
    }
};

fn debugCallbackValidation(message_severity: vk.DebugUtilsMessageSeverityFlagsEXT, _: vk.DebugUtilsMessageTypeFlagsEXT, callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT, _: ?*anyopaque) callconv(.c) vk.Bool32 {
    const data = callback_data.?.*;
    const verbose_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .verbose_bit_ext = true }).toInt();
    const info_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .info_bit_ext = true }).toInt();
    const warning_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .warning_bit_ext = true }).toInt();
    const error_severity = comptime (vk.DebugUtilsMessageSeverityFlagsEXT{ .error_bit_ext = true }).toInt();

    const color: std.Io.Terminal.Color = switch (message_severity.toInt()) {
        verbose_severity => .dim,
        info_severity => .green,
        warning_severity => .yellow,
        error_severity => .red,
        else => unreachable,
    };

    var buffer: [1024]u8 = undefined;
    const stderr_lock = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const writer = &stderr_lock.file_writer.interface;

    const terminal = stderr_lock.terminal();
    terminal.setColor(color) catch {};
    writer.print("{s}\n", .{ data.p_message.? }) catch @panic("unable to write validation error to stderr");
    terminal.setColor(.reset) catch {};

    // write stack trace for validation error
    switch (@import("build_options").vk_validation) {
        .print => {
            writeMinimalStacktrace(@returnAddress(), terminal);
        },
        .panic => {
            writer.flush() catch @panic("unable to flush writer");
            @panic("validation error encountered");
        },
        .ignore => unreachable,
    }

    writer.flush() catch @panic("unable to flush writer");

    return .false;
}

// TODO: this'll need more careful handling for multithreading
fn debugCallbackDeviceAddressBinding(_: vk.DebugUtilsMessageSeverityFlagsEXT, _: vk.DebugUtilsMessageTypeFlagsEXT, callback_data_ptr: ?*const vk.DebugUtilsMessengerCallbackDataEXT, user_data_opaque: ?*anyopaque) callconv(.c) vk.Bool32 {
    const user_data: *DebugCallbackUserData = @ptrCast(@alignCast(user_data_opaque));
    const callback_data = callback_data_ptr.?.*;
    const device_address_binding_callback_data: *const vk.DeviceAddressBindingCallbackDataEXT = @ptrCast(@alignCast(callback_data.p_next));
    const object = callback_data.p_objects.?[0..callback_data.object_count][0];
    const binding = DeviceAddressBindingTracker.BindingEvent {
        .range = .{
            .base = device_address_binding_callback_data.base_address,
            .size = device_address_binding_callback_data.size,
        },
        .internal = device_address_binding_callback_data.flags.contains(.{ .internal_object_bit_ext = true }),
        .object_type = object.object_type,
        .object_name = if (object.p_object_name) |name| user_data.allocator.dupe(u8, std.mem.span(name)) catch @panic("OOM") else null,
        .type = switch (device_address_binding_callback_data.binding_type) {
            .bind_ext => .bind,
            .unbind_ext => .unbind,
            else => unreachable,
        },
    };
    user_data.device_address_binding_tracker.append(user_data.allocator, binding) catch @panic("OOM");
    return .false;
}

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

const BindingReport = struct {
    messenger: vk.DebugUtilsMessengerEXT,
    user_data: *DebugCallbackUserData,

    fn create(allocator: std.mem.Allocator, instance: Instance) !BindingReport {
        const user_data = try DebugCallbackUserData.create(allocator);
        errdefer user_data.destroy();
        const messenger = try instance.createDebugUtilsMessengerEXT(&.{
            .message_severity = .{ .info_bit_ext = true, .warning_bit_ext = true, .error_bit_ext = true },
            .message_type = .{ .device_address_binding_bit_ext = true },
            .pfn_user_callback = debugCallbackDeviceAddressBinding,
            .p_user_data = user_data,
        }, null);
        return .{ .messenger = messenger, .user_data = user_data };
    }

    fn destroy(self: BindingReport, instance: Instance) void {
        instance.destroyDebugUtilsMessengerEXT(self.messenger, null);
        self.user_data.destroy();
    }
};

base: Base,
instance_dispatch: *vk.InstanceWrapper,
device_dispatch: *vk.DeviceWrapper,
instance: Instance,
device: Device,

physical_device: PhysicalDevice,

debug_messenger: if (validate) vk.DebugUtilsMessengerEXT else void,
binding_report: if (validate) ?BindingReport else void,

queue: Queue,

memory_types: MemoryTypes,

const Self = @This();

const QueueFamilyAcceptable = fn(vk.Instance, vk.PhysicalDevice, u32) bool;
fn returnsTrue(_: vk.Instance, _: vk.PhysicalDevice, _: u32) bool { return true; }

const core_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_push_descriptor.name,
};

pub const VulkanRequirements = struct {
    instance_extensions: []const [*:0]const u8 = &.{},
    device_extensions: []const [*:0]const u8 = &.{},
    features: []const *vk.BaseOutStructure = &.{}, // note that this may be mutated
    queueFamilyAcceptable: *const QueueFamilyAcceptable = returnsTrue,

    pub fn merge(comptime self: VulkanRequirements, comptime other: VulkanRequirements) VulkanRequirements {
        const Wrapper = struct {
            fn queueFamilyAcceptable(instance: vk.Instance, physical_device: vk.PhysicalDevice, idx: u32) bool {
                return self.queueFamilyAcceptable(instance, physical_device, idx) and other.queueFamilyAcceptable(instance, physical_device, idx);
            }
        };
        return VulkanRequirements {
            .instance_extensions = self.instance_extensions ++ other.instance_extensions,
            .device_extensions = self.device_extensions ++ other.device_extensions,
            .features = self.features ++ other.features,
            .queueFamilyAcceptable = Wrapper.queueFamilyAcceptable,
        };
    }

    pub fn featureChain(self: VulkanRequirements) ?*const anyopaque {
        if (self.features.len == 0) return null;

        for (self.features[0..self.features.len - 1], self.features[1..]) |curr, next| {
            curr.p_next = next;
        }
        self.features[self.features.len - 1].p_next = null;

        return self.features[0];
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

    const debug_messenger = if (validate) try instance.createDebugUtilsMessengerEXT(&.{
        .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true },
        .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
        .pfn_user_callback = debugCallbackValidation,
    }, null) else undefined;
    errdefer if (validate) instance.destroyDebugUtilsMessengerEXT(debug_messenger, null);

    const physical_device = try PhysicalDevice.pick(instance, allocator, requirements.queueFamilyAcceptable, requirements.device_extensions);

    const binding_report = if (validate) blk: {
        if (physical_device.supports_device_address_binding_report_extension) {
            break :blk try BindingReport.create(allocator, instance);
        } else break :blk null;
    } else {};
    const device_handle = try physical_device.createLogicalDevice(allocator, instance, requirements.device_extensions, requirements.featureChain());
    const device_dispatch = try allocator.create(vk.DeviceWrapper);
    device_dispatch.* = vk.DeviceWrapper.load(device_handle, instance_dispatch.dispatch.vkGetDeviceProcAddr.?);
    const device = Device.init(device_handle, device_dispatch);
    errdefer device.destroyDevice(null);

    const queue_handle = device.getDeviceQueue(physical_device.queue_family_index, 0);
    const queue = Queue.init(queue_handle, device_dispatch);

    return Self {
        .base = base,
        .instance_dispatch = instance_dispatch,
        .instance = instance,
        .debug_messenger = debug_messenger,
        .binding_report = binding_report,
        .device_dispatch = device_dispatch,
        .device = device,
        .physical_device = physical_device,

        .queue = queue,

        .memory_types = MemoryTypes.create(instance, physical_device),
    };
}

pub fn destroy(self: Self, allocator: std.mem.Allocator) void {
    self.device.destroyDevice(null);
    allocator.destroy(self.device_dispatch);

    if (validate) {
        if (self.binding_report) |binding_report| binding_report.destroy(self.instance);
        self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    }
    self.instance.destroyInstance(null);
    allocator.destroy(self.instance_dispatch);
    self.base.destroy();
}

pub fn handleDeviceLost(self: Self, transient: std.mem.Allocator) !void {
    var buffer: [1024]u8 = undefined;
    const stderr_lock = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const stderr = &stderr_lock.file_writer.interface;

    try stderr.writeAll("Device lost detected.\n");

    if (self.physical_device.supports_device_fault_extension) {
        var counts = vk.DeviceFaultCountsEXT {
            .address_info_count = undefined,
            .vendor_info_count = undefined,
            .vendor_binary_size = undefined,
        };
        const res1 = try self.device.getDeviceFaultInfoEXT(&counts, null);
        std.debug.assert(res1 == .success);

        const address_infos = try transient.alloc(vk.DeviceFaultAddressInfoEXT, counts.address_info_count);
        defer transient.free(address_infos);

        const vendor_infos = try transient.alloc(vk.DeviceFaultVendorInfoEXT, counts.vendor_info_count);
        defer transient.free(vendor_infos);

        const vendor_binary = try transient.alloc(u8, counts.vendor_binary_size);
        defer transient.free(vendor_binary);

        var info = vk.DeviceFaultInfoEXT {
            .description = undefined,
            .p_address_infos = @ptrCast(address_infos.ptr),
            .p_vendor_infos = @ptrCast(vendor_infos.ptr),
            .p_vendor_binary_data = vendor_binary.ptr,
        };

        const res2 = try self.device.getDeviceFaultInfoEXT(&counts, &info);
        std.debug.assert(res2 == .success);

        try stderr.print("Description: {s}\n", .{ info.description });
        if (address_infos.len != 0) try stderr.writeAll("Addresses:\n");
        for (address_infos) |address_info| {
            const lower_address = address_info.reported_address & ~(address_info.address_precision - 1);
            const upper_address = address_info.reported_address | (address_info.address_precision - 1);
            try stderr.print("  {s}: 0x{X}..=0x{X}\n", .{@tagName(address_info.address_type), lower_address, upper_address});
        }
        if (validate) {
            if (self.binding_report) |binding_report| {
                const bindings = binding_report.user_data.device_address_binding_tracker.bindings.items;
                try stderr.writeAll("Bound Addresses:\n");
                for (bindings) |binding| {
                    try stderr.print("  0x{X}..=0x{X}: ", .{binding.range.base, binding.range.base + binding.range.size});
                    try stderr.writeAll(if (binding.internal) "internal " else "external ");
                    try stderr.writeAll(@tagName(binding.object_type));
                    if (binding.object_name) |name| {
                        try stderr.writeAll(" ");
                        try stderr.print("{s}", .{name});
                    }
                    try stderr.writeAll(" ");
                    try stderr.writeAll(@tagName(binding.type));
                    try stderr.writeAll("\n");
                }
            }
        }
        if (vendor_infos.len != 0) try stderr.writeAll("Vendor data:\n");
        for (vendor_infos) |vendor_info| {
            try stderr.print("  {}:{}: {s}\n", .{vendor_info.vendor_fault_code, vendor_info.vendor_fault_data, vendor_info.description});
        }
        if (vendor_binary.len != 0) {
            var hasher = std.hash.XxHash3.init(0);
            hasher.update(&info.description);
            hasher.update(vendor_binary);
            hasher.update(@as([]const u8, @ptrCast(address_infos)));
            hasher.update(@as([]const u8, @ptrCast(vendor_infos)));

            const hash = hasher.final();

            var file_name_buffer: [32]u8 = undefined;
            const file_name = std.fmt.bufPrint(&file_name_buffer, "gpu_dump_{x}.bin", .{ hash }) catch unreachable;
            try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = file_name, .data = vendor_binary });
            try stderr.print("Wrote vendor binary to {s}\n", .{file_name});
        } else {
            try stderr.writeAll("Vendor binary unvailable");
        }
    } else {
        try stderr.writeAll("VK_EXT_DEVICE_FAULT unavailable, unable to query fault information.\n");
    }
}

const PhysicalDevice = struct {
    handle: vk.PhysicalDevice,
    supports_device_fault_extension: bool,
    supports_device_fault_extension_vendor_binary: bool,
    supports_device_address_binding_report_extension: bool,
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

        const all_extensions = try std.mem.concat(transient, [*:0]const u8, &[_][]const [*:0]const u8{ &core_device_extensions, extensions });
        defer transient.free(all_extensions);

        return for (devices) |device| {
            if (try PhysicalDevice.deviceExtensionsAvailable(instance, device, transient, all_extensions)) {
                if (pickQueueFamily(instance, transient, device, queueFamilyAcceptable)) |index| {

                    const available_extensions = try instance.enumerateDeviceExtensionPropertiesAlloc(device, null, transient);
                    defer transient.free(available_extensions);

                    const supports_device_fault_extension = for (available_extensions) |extension| {
                        if (std.mem.orderZ(u8, vk.extensions.ext_device_fault.name, @ptrCast(&extension.extension_name)) == .eq) {
                            break true;
                        }
                    } else false;

                    const supports_device_fault_extension_vendor_binary = if (supports_device_fault_extension) blk: {
                        var device_fault_features = vk.PhysicalDeviceFaultFeaturesEXT {
                            .device_fault = undefined,
                            .device_fault_vendor_binary = undefined,
                        };

                        var features = vk.PhysicalDeviceFeatures2 {
                            .p_next = &device_fault_features,
                            .features = undefined,
                        };

                        instance.getPhysicalDeviceFeatures2(device, &features);

                        break :blk device_fault_features.device_fault_vendor_binary == .true;
                    } else false;

                    const supports_device_address_binding_report_extension = if (validate and supports_device_fault_extension) for (available_extensions) |extension| {
                        if (std.mem.orderZ(u8, vk.extensions.ext_device_address_binding_report.name, @ptrCast(&extension.extension_name)) == .eq) {
                            break true;
                        }
                    } else false else false;

                    break PhysicalDevice {
                        .handle = device,
                        .supports_device_fault_extension = supports_device_fault_extension,
                        .supports_device_fault_extension_vendor_binary = supports_device_fault_extension_vendor_binary,
                        .supports_device_address_binding_report_extension = supports_device_address_binding_report_extension,
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

    fn createLogicalDevice(self: *const PhysicalDevice, transient: std.mem.Allocator, instance: Instance, extensions: []const [*:0]const u8, features: ?*const anyopaque) !vk.Device {
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
            .synchronization_2 = .true,
            .dynamic_rendering = .true, // technically not required by core lib, but afaik since vk 1.3 requires it this can't hurt?
        };

        const vulkan_12_features = vk.PhysicalDeviceVulkan12Features {
            .p_next = &vulkan_13_features,
            .buffer_device_address = .true,
            .scalar_block_layout = .true,
            .shader_sampled_image_array_non_uniform_indexing = .true,
            .runtime_descriptor_array = .true,
            .descriptor_binding_partially_bound = .true,
            .host_query_reset = .true,
            .descriptor_binding_update_unused_while_pending = .true,
        };

        const device_address_binding_report_features = vk.PhysicalDeviceAddressBindingReportFeaturesEXT {
            .p_next = @constCast(&vulkan_12_features),
            .report_address_binding = .true,
        };

        const device_fault_features = vk.PhysicalDeviceFaultFeaturesEXT {
            .p_next = if (self.supports_device_address_binding_report_extension) @constCast(&device_address_binding_report_features) else @constCast(&vulkan_12_features),
            .device_fault = .true,
            .device_fault_vendor_binary = if (self.supports_device_fault_extension_vendor_binary) .true else .false,
        };

        const core_extensions = if (self.supports_device_fault_extension) if (self.supports_device_address_binding_report_extension) &(core_device_extensions ++ [_][*:0]const u8{ vk.extensions.ext_device_fault.name, vk.extensions.ext_device_address_binding_report.name }) else &(core_device_extensions ++ [_][*:0]const u8{ vk.extensions.ext_device_fault.name }) else &core_device_extensions;
        const all_extensions = try std.mem.concat(transient, [*:0]const u8, &[_][]const [*:0]const u8{ core_extensions, extensions });
        defer transient.free(all_extensions);

        const final_features: *const anyopaque = if (self.supports_device_fault_extension) @ptrCast(&device_fault_features) else @ptrCast(&vulkan_12_features);

        return try instance.createDevice(
            self.handle,
            &.{
                .queue_create_info_count = queue_create_info.len,
                .p_queue_create_infos = &queue_create_info,
                .enabled_layer_count = 0,
                .pp_enabled_layer_names = null,
                .enabled_extension_count = @as(u32, @intCast(all_extensions.len)),
                .pp_enabled_extension_names = all_extensions.ptr,
                .p_enabled_features = &.{
                    .shader_int_64 = .true,
                },
                .p_next = final_features,
            },
            null,
        );
    }
};

