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
[[vk::binding(5, 0)]] StructuredBuffer<Material> dMaterials;

// EMISSIVE TRIANGLES
[[vk::binding(6, 0)]] Texture1D<float> dTrianglePower;
[[vk::binding(7, 0)]] StructuredBuffer<TriangleMetadata> dTriangleMetadata;
[[vk::binding(8, 0)]] StructuredBuffer<uint> dGeometryToTrianglePowerOffset;
[[vk::binding(9, 0)]] StructuredBuffer<uint> dEmissiveTriangleCount;

// BACKGROUND
[[vk::combinedImageSampler]] [[vk::binding(10, 0)]] Texture2D<float3> dBackgroundRgbTexture;
[[vk::combinedImageSampler]] [[vk::binding(10, 0)]] SamplerState dBackgroundSampler;
[[vk::binding(11, 0)]] Texture2D<float> dBackgroundLuminanceTexture;

// OUTPUT
[[vk::binding(12, 0)]] RWTexture2D<float4> dOutputImage;

// PUSH CONSTANTS
struct PushConsts {
    Camera camera;
    uint sampleCount;
    Homogeneous globalMedium;
};
[[vk::push_constant]] PushConsts pushConsts;

template <class Integrator>
void integrate(Integrator integrator) {
    const uint2 imageCoords = DispatchRaysIndex().xy;
    const uint2 imageSize = DispatchRaysDimensions().xy;

    World world;
    world.instances = dInstances;
    world.worldToInstance = dWorldToInstance;
    world.meshes = dMeshes;
    world.geometries = dGeometries;
    world.materials = dMaterials;

    Scene scene;
    scene.tlas = dTLAS;
    scene.world = world;
    scene.envMap = EnvMap::create(dBackgroundRgbTexture, dBackgroundSampler, dBackgroundLuminanceTexture);
    scene.meshLights = MeshLights::create(dTrianglePower, dTriangleMetadata, dGeometryToTrianglePowerOffset, dEmissiveTriangleCount[0], world);
    scene.globalMedium = pushConsts.globalMedium;

    Rng rng = Rng::fromSeed(uint3(pushConsts.sampleCount, imageCoords.x, imageCoords.y));

    // set up initial ray
    const float2 jitter = float2(rng.getFloat(), rng.getFloat());
    const float2 imageUV = (imageCoords + jitter) / imageSize;
    const Ray initialRay = pushConsts.camera.generateRay(imageUV, float2(rng.getFloat(), rng.getFloat()));

    // trace the ray
    WavelengthSample w = WavelengthSample::sampleVisible(rng.getFloat());
    const float newSample = integrator.incomingRadiance(scene, initialRay, w.λ, rng);

    // accumulate
    const float3 priorSampleAverage = pushConsts.sampleCount == 0 ? 0 : dOutputImage[imageCoords].xyz;
    dOutputImage[imageCoords] = float4(accumulate(priorSampleAverage, Spectrum::toLinearSRGB(w.λ, newSample) / w.pdf, pushConsts.sampleCount), 1);
}

struct Attributes
{
    float2 barycentrics;
};

[shader("closesthit")]
void closesthit(inout Intersection its, in Attributes attribs) {
    its.instanceIndex = InstanceIndex();
    its.geometryIndex = GeometryIndex();
    its.primitiveIndex = PrimitiveIndex();
    its.barycentrics = attribs.barycentrics;
}

[shader("miss")]
void miss(inout Intersection its) {
    its = Intersection::createMiss();
}

[shader("miss")]
void shadowmiss(inout ShadowIntersection its) {
    its.inShadow = false;
}

