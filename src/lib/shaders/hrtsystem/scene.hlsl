#pragma once

#include "light.hlsl"
#include "world.hlsl"
#include "medium.hlsl"

struct Scene {
    RaytracingAccelerationStructure tlas;
    World world;
    EnvMap envMap;
    MeshLights meshLights;
    Homogeneous globalMedium;
    float globalIOR;
};
