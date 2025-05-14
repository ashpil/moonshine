#include "intersection.hlsl"
#include "camera.hlsl"
#include "scene.hlsl"
#include "integrator.hlsl"
#include "medium.hlsl"

// I use the `d` prefix to indicate a descriptor variable
// because as a functional programmer impure functions scare me

// GEOMETRY
[[vk::binding(0, 0)]] RaytracingAccelerationStructure dTLAS;
[[vk::binding(1, 0)]] StructuredBuffer<Instance> dInstances;
[[vk::binding(2, 0)]] StructuredBuffer<row_major float3x4> dWorldToInstance;
[[vk::binding(3, 0)]] StructuredBuffer<Mesh> dMeshes;
[[vk::binding(4, 0)]] StructuredBuffer<Geometry> dGeometries;
[[vk::binding(5, 0)]] StructuredBuffer<Model> dModels;
[[vk::binding(6, 0)]] StructuredBuffer<Material> dMaterials;

// EMISSIVE TRIANGLES
[[vk::binding(7, 0)]] StructuredBuffer<float3> dInstancePower;

// BACKGROUND
[[vk::combinedImageSampler]] [[vk::binding(8, 0)]] Texture2D<float3> dBackgroundTexture;
[[vk::combinedImageSampler]] [[vk::binding(8, 0)]] SamplerState dBackgroundSampler;

// OUTPUT
[[vk::binding(9, 0)]] RWTexture2D<float4> dOutputImage;

// PUSH CONSTANTS
struct PushConsts {
    uint instanceCount;
    Camera camera;
    uint sampleCount;
    ChromaticVolume globalVolume;
    float3x3 backgroundToWorld;
    uint seed;
};
[[vk::push_constant]] PushConsts pushConsts;

enum class IntegratorType : uint {
    DirectLight,
    PathTracing,
    VolumePathTracing,
};

[[vk::constant_id(0)]] const uint dIntegratorType = 1;
[[vk::constant_id(1)]] const uint dDirectLightEnvSamples = 1;  // how many times the environment map should be sampled for light
[[vk::constant_id(2)]] const uint dDirectLightMeshSamples = 1; // how many times emissive meshes should be sampled for light
[[vk::constant_id(3)]] const uint dDirectLightBrdfSamples = 1; // how many times BRDF should be sampled for light
[[vk::constant_id(4)]] const uint dPathTracingRussianRouletteDepth = 3; // at which bounce depth russian roulette should start
[[vk::constant_id(5)]] const uint dPathTracingEnvSamplesPerBounce = 1;  // how many times the environment map should be sampled per bounce for light
[[vk::constant_id(6)]] const uint dPathTracingMeshSamplesPerBounce = 1; // how many times emissive meshes should be sampled per bounce for light
[[vk::constant_id(7)]] const uint dVolumePathTracingRussianRouletteDepth = 3; // at which bounce depth russian roulette should start
[[vk::constant_id(8)]] const uint dVolumePathTracingEnvSamplesPerBounce = 1;  // how many times the environment map should be sampled per bounce for light
[[vk::constant_id(9)]] const uint dVolumePathTracingMeshSamplesPerBounce = 1; // how many times emissive meshes should be sampled per bounce for light

[numthreads(8, 8, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
	const uint2 imageCoords = dispatchXYZ.xy;
	const uint2 imageSize = textureDimensions(dOutputImage);

	if (any(imageCoords >= imageSize)) return;

    World world;
    world.instances = dInstances;
    world.worldToInstance = dWorldToInstance;
    world.meshes = dMeshes;
    world.models = dModels;
    world.geometries = dGeometries;
    world.materials = dMaterials;

    Scene scene;
    scene.tlas = dTLAS;
    scene.world = world;
    scene.envMap = EnvMap::create(pushConsts.backgroundToWorld, dBackgroundTexture, dBackgroundSampler);
    scene.instanceLights = InstanceLights::create(dInstancePower, pushConsts.instanceCount, world);
    scene.globalVolume = pushConsts.globalVolume;

    Rng rng = Rng::fromSeed(uint3(pushConsts.seed, imageCoords.x, imageCoords.y));

    // set up initial ray
    const float2 jitter = float2(rng.getFloat(), rng.getFloat());
    const float2 imageUV = (imageCoords + jitter) / imageSize;
    const Ray initialRay = pushConsts.camera.generateRay(imageUV, float2(rng.getFloat(), rng.getFloat()));

    // trace the ray
    WavelengthSample w = WavelengthSample::sampleVisible(rng.getFloat());

    const IntegratorType integratorType = (IntegratorType)dIntegratorType;
    float radiance;
    switch (integratorType) {
        case IntegratorType::DirectLight: {
            const DirectLightIntegrator integrator = DirectLightIntegrator::create(dDirectLightEnvSamples, dDirectLightMeshSamples, dDirectLightBrdfSamples);
            radiance = integrator.incomingRadiance(scene, initialRay, w.λ, rng);
            break;
        }
        case IntegratorType::PathTracing: {
            const PathTracingIntegrator integrator = PathTracingIntegrator::create(dPathTracingRussianRouletteDepth, dPathTracingEnvSamplesPerBounce, dPathTracingMeshSamplesPerBounce);
            radiance = integrator.incomingRadiance(scene, initialRay, w.λ, rng);
            break;
        }
        case IntegratorType::VolumePathTracing: {
            const VolumePathTracingIntegrator integrator = VolumePathTracingIntegrator::create(dVolumePathTracingRussianRouletteDepth, dVolumePathTracingEnvSamplesPerBounce, dVolumePathTracingMeshSamplesPerBounce);
            radiance = integrator.incomingRadiance(scene, initialRay, w.λ, rng);
            break;
        }
    }

    // accumulate
    const float3 priorSampleAverage = pushConsts.sampleCount == 0 ? 0 : dOutputImage[imageCoords].xyz;
    const float3 newSample = Spectrum::toLinearSRGB(w.λ, radiance) / w.pdf;
    const float3 newAverage = accumulate(priorSampleAverage, newSample, pushConsts.sampleCount);
    dOutputImage[imageCoords] = float4(newAverage, 1);
}
