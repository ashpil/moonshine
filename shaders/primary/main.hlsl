#include "bindings.hlsl"
#include "intersection.hlsl"
#include "camera.hlsl"
#include "integrator.hlsl"

void storeColor(float3 color) {
    uint2 imageCoords = DispatchRaysIndex().xy;
    float3 previouslyAccumulated = pushConsts.sampleCount == 0 ? float3(0, 0, 0) : dAccumulationImage[imageCoords].rgb;
    dAccumulationImage[imageCoords] = float4(previouslyAccumulated + color, 1.0);
    dOutputImage[imageCoords] = float4((previouslyAccumulated + color) / (pushConsts.sampleCount + SAMPLES_PER_RUN), 1.0);
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

    // the result that we write to our buffer
    float3 color = float3(0.0, 0.0, 0.0);

    for (uint sampleCount = 0; sampleCount < SAMPLES_PER_RUN; sampleCount++) {
        // create rng for this sample
        float rngSeed = ((pushConsts.sampleCount + sampleCount) * DispatchRaysDimensions().y + DispatchRaysIndex().y) * DispatchRaysDimensions().x + DispatchRaysIndex().x;
        Rng rng = Rng::fromSeed(rngSeed);

        // set up initial directions for first bounce
        RayDesc initialRay = pushConsts.camera.generateRay(dispatchUV(float2(rng.getFloat(), rng.getFloat())), float2(rng.getFloat(), rng.getFloat()));

        // trace the ray
        color += integrator.incomingRadiance(initialRay, rng);
    }

    storeColor(color);
}

[shader("closesthit")]
void closesthit(inout Intersection its, in float2 attribs) {
    its.instanceID = InstanceID();
    its.instanceIndex = InstanceIndex();
    its.geometryIndex = GeometryIndex();
    its.primitiveIndex = PrimitiveIndex();
    its.attribs = attribs;
}

[shader("miss")]
void miss(inout Intersection its) {
    its = Intersection::createMiss();
}

[shader("miss")]
void shadowmiss(inout ShadowIntersection its) {
    its.inShadow = false;
}

