pub const Accel = @import("Accel.zig");
pub const Allocator = @import("Allocator.zig");
pub const Background = @import("Background.zig");
pub const Camera = @import("Camera.zig");
pub const Commands = @import("Commands.zig");
pub const descriptor = @import("descriptor.zig");
pub const ImageManager = @import("ImageManager.zig");
pub const MeshManager = @import("MeshManager.zig");
pub const MaterialManager = @import("MaterialManager.zig");
pub const Film = @import("Film.zig");
pub const pipeline = @import("pipeline.zig");
pub const World = @import("World.zig");
pub const Scene = @import("Scene.zig");

const vk = @import("vulkan");
pub const required_device_extensions = [_][*:0]const u8{
    vk.extension_info.khr_deferred_host_operations.name,
    vk.extension_info.khr_acceleration_structure.name,
    vk.extension_info.khr_ray_tracing_pipeline.name,
};

pub const required_device_features = vk.PhysicalDeviceRayTracingPipelineFeaturesKHR {
    .p_next = @constCast(&vk.PhysicalDeviceAccelerationStructureFeaturesKHR {
        .acceleration_structure = vk.TRUE,
    }),
    .ray_tracing_pipeline = vk.TRUE,
};

pub const required_device_functions = vk.DeviceCommandFlags {
    .createRayTracingPipelinesKHR = true,
    .cmdBuildAccelerationStructuresKHR = true,
    .destroyAccelerationStructureKHR = true,
    .createAccelerationStructureKHR = true,
    .getAccelerationStructureBuildSizesKHR = true,
    .getAccelerationStructureDeviceAddressKHR = true,
    .getRayTracingShaderGroupHandlesKHR = true,
    .cmdTraceRaysKHR = true,
    .cmdWriteAccelerationStructuresPropertiesKHR = true,
    .cmdCopyAccelerationStructureKHR = true,
};
