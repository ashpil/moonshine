#include "main_shared.hlsl"

[[vk::constant_id(0)]] const uint dRussianRouletteDepth = 3;
[[vk::constant_id(1)]] const uint dEnvSamplesPerBounce = 1;  // how many times the environment map should be sampled per bounce for light
[[vk::constant_id(2)]] const uint dMeshSamplesPerBounce = 1; // how many times emissive meshes should be sampled per bounce for light

[shader("raygeneration")]
void raygen() {
    const PathTracingIntegrator integrator = PathTracingIntegrator::create(dRussianRouletteDepth, dEnvSamplesPerBounce, dMeshSamplesPerBounce);
    integrate(integrator);
}

