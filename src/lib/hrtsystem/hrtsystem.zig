pub const Accel = @import("Accel.zig");
pub const CameraManager = @import("CameraManager.zig");
pub const MeshManager = @import("MeshManager.zig");
pub const MaterialManager = @import("MaterialManager.zig");
pub const ModelManager = @import("ModelManager.zig");
pub const BackgroundManager = @import("BackgroundManager.zig");
pub const ObjectPicker = @import("ObjectPicker.zig");
pub const pipeline = @import("pipeline.zig");
pub const World = @import("World.zig");
pub const Scene = @import("Scene.zig");
pub const ConstantSpectra = @import("ConstantSpectra.zig");
pub const Sensor = @import("Sensor.zig");

const vk = @import("vulkan");

pub const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_deferred_host_operations.name,
    vk.extensions.khr_acceleration_structure.name,
    vk.extensions.khr_ray_tracing_pipeline.name,
};

pub const required_device_features = vk.PhysicalDeviceRayTracingPipelineFeaturesKHR {
    .p_next = @constCast(&vk.PhysicalDeviceAccelerationStructureFeaturesKHR {
        .acceleration_structure = vk.TRUE,
    }),
    .ray_tracing_pipeline = vk.TRUE,
};

pub const required_vulkan_functions = [_]vk.ApiInfo {
    .{
        .device_commands = .{
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
            .cmdClearColorImage = true,
            .cmdFillBuffer = true,
        },
    },
};
