#pragma once

#include "light.hlsl"

struct Scene {
    RaytracingAccelerationStructure tlas;
    StructuredBuffer<Instance> instances;
    StructuredBuffer<row_major float3x4> worldToInstance;

    StructuredBuffer<Mesh> meshes;
    StructuredBuffer<Geometry> geometries;

    StructuredBuffer<MaterialVariantData> materials;

    EnvMap envMap;
    MeshLights meshLights;
};
