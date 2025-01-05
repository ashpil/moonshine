#pragma once

#include "light.hlsl"
#include "world.hlsl"
#include "volume.hlsl"

struct Scene {
    RaytracingAccelerationStructure tlas;
    World world;
    EnvMap envMap;
    MeshLights meshLights;
    ChromaticVolume globalVolume;
};
