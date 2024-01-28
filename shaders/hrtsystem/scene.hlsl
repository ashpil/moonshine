#pragma once

#include "light.hlsl"
#include "world.hlsl"

struct Scene {
    RaytracingAccelerationStructure tlas;
    World world;
    EnvMap envMap;
    MeshLights meshLights;
};
