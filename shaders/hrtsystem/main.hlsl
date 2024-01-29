#include "bindings.hlsl"
#include "intersection.hlsl"
#include "camera.hlsl"
#include "scene.hlsl"
#include "integrator.hlsl"

// set 0 - textures
// set 1 - scene
// set 2 - background
// set 3 - output
// TODO: should be 0 for textures and 1 for everything else

// I use the `d` prefix to indicate a descriptor variable
// because as a functional programmer impure functions scare me

// GEOMETRY
[[vk::binding(0, 1)]] RaytracingAccelerationStructure dTLAS;
[[vk::binding(1, 1)]] StructuredBuffer<Instance> dInstances;
[[vk::binding(2, 1)]] StructuredBuffer<row_major float3x4> dWorldToInstance;
[[vk::binding(3, 1)]] StructuredBuffer<AliasEntry<LightAliasData> > dEmitterAliasTable;
[[vk::binding(4, 1)]] StructuredBuffer<Mesh> dMeshes;
[[vk::binding(5, 1)]] StructuredBuffer<Geometry> dGeometries;
[[vk::binding(7, 1)]] StructuredBuffer<MaterialVariantData> dMaterials;

// BACKGROUND
[[vk::combinedImageSampler]] [[vk::binding(0, 2)]] Texture2D<float3> dBackgroundTexture;
[[vk::combinedImageSampler]] [[vk::binding(0, 2)]] SamplerState dBackgroundSampler;
[[vk::binding(1, 2)]] StructuredBuffer<AliasEntry<float> > dBackgroundMarginalAlias; // size: dBackgroundTexture.height
[[vk::binding(2, 2)]] StructuredBuffer<AliasEntry<float> > dBackgroundConditionalAlias; // size: dBackgroundTexture.height * dBackgroundTexture.width

// OUTPUT
[[vk::binding(0, 3)]] RWTexture2D<float4> dOutputImage;

// PUSH CONSTANTS
struct PushConsts {
	Camera camera;
	uint sampleCount;
};
[[vk::push_constant]] PushConsts pushConsts;

// SPECIALIZATION CONSTANTS
[[vk::constant_id(0)]] const uint SAMPLES_PER_RUN = 1;
[[vk::constant_id(1)]] const uint MAX_BOUNCES = 4;
[[vk::constant_id(2)]] const uint ENV_SAMPLES_PER_BOUNCE = 1;     // how many times the environment map should be sampled per bounce for light
[[vk::constant_id(3)]] const uint MESH_SAMPLES_PER_BOUNCE = 1;    // how many times emissive meshes should be sampled per bounce for light

// https://www.nu42.com/2015/03/how-you-average-numbers.html
void storeColor(float3 sampledColor) {
    uint2 imageCoords = DispatchRaysIndex().xy;
    if (pushConsts.sampleCount == 0) {
        dOutputImage[imageCoords] = float4(sampledColor / SAMPLES_PER_RUN, 1.0);
    } else {
        float3 priorSampleAverage = dOutputImage[imageCoords].rgb;
        dOutputImage[imageCoords] += float4((sampledColor - priorSampleAverage) / (pushConsts.sampleCount + SAMPLES_PER_RUN), 1.0);
    }
}

// returns uv of dispatch in [0..1]x[0..1], with slight variation based on rand
float2 dispatchUV(float2 rand) {
    float2 randomCenter = float2(0.5, 0.5) + 0.5 * squareToGaussian(rand);
    float2 uv = (float2(DispatchRaysIndex().xy) + randomCenter) / float2(DispatchRaysDimensions().xy);
    uv.y = -(uv.y - 1);
    return uv;
}

[shader("raygeneration")]
void raygen() {
    PathTracingIntegrator integrator = PathTracingIntegrator::create(MAX_BOUNCES, ENV_SAMPLES_PER_BOUNCE, MESH_SAMPLES_PER_BOUNCE);

    World world;
    world.instances = dInstances;
    world.worldToInstance = dWorldToInstance;
    world.meshes = dMeshes;
    world.geometries = dGeometries;
    world.materials = dMaterials;

    Scene scene;
    scene.tlas = dTLAS;
    scene.world = world;
    scene.envMap = EnvMap::create(dBackgroundTexture, dBackgroundSampler, dBackgroundMarginalAlias, dBackgroundConditionalAlias);
    scene.meshLights = MeshLights::create(dEmitterAliasTable, world);

    // the result that we write to our buffer
    float3 color = float3(0.0, 0.0, 0.0);
    
    for (uint sampleCount = 0; sampleCount < SAMPLES_PER_RUN; sampleCount++) {
        // create rng for this sample
        Rng rng = Rng::fromSeed(uint3(pushConsts.sampleCount + sampleCount, DispatchRaysIndex().x, DispatchRaysIndex().y));

        // set up initial directions for first bounce
        RayDesc initialRay = pushConsts.camera.generateRay(dOutputImage, dispatchUV(float2(rng.getFloat(), rng.getFloat())), float2(rng.getFloat(), rng.getFloat()));

        // trace the ray
        color += integrator.incomingRadiance(scene, initialRay, rng);
    }

    storeColor(color);
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

