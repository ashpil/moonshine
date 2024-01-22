#include "bindings.hlsl"
#include "intersection.hlsl"
#include "camera.hlsl"
#include "integrator.hlsl"

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
    PathTracingIntegrator integrator = PathTracingIntegrator::create(MAX_BOUNCES, ENV_SAMPLES_PER_BOUNCE, MESH_SAMPLES_PER_BOUNCE, pushConsts.backgroundTexture);

    // the result that we write to our buffer
    float3 color = float3(0.0, 0.0, 0.0);

    for (uint sampleCount = 0; sampleCount < SAMPLES_PER_RUN; sampleCount++) {
        // create rng for this sample
        Rng rng = Rng::fromSeed(uint3(pushConsts.sampleCount + sampleCount, DispatchRaysIndex().x, DispatchRaysIndex().y));

        // set up initial directions for first bounce
        RayDesc initialRay = pushConsts.camera.generateRay(dispatchUV(float2(rng.getFloat(), rng.getFloat())), float2(rng.getFloat(), rng.getFloat()));

        // trace the ray
        color += integrator.incomingRadiance(initialRay, rng);
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

