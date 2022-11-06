// space 0 - scene
// space 1 - background
// space 2 - display

RaytracingAccelerationStructure TLAS : register(t0, space0);
RWTexture2D<float4> displayImage : register(u0, space2);
RWTexture2D<float4> accumulationImage : register(u1, space2);

#include "math.hlsl"
#include "payload.hlsl"
#include "reflection_frame.hlsl"
#include "random.hlsl"
#include "microfacet.hlsl"
#include "background.hlsl"

struct Camera {
    float3 origin;
    float3 lower_left_corner;
    float3 horizontal;
    float3 vertical;
    float3 u, v;
    float lens_radius;
};

struct PushConsts {
	Camera camera;
	uint numAccumulatedFrames;
};
[[vk::push_constant]] PushConsts pushConsts;

[[vk::constant_id(0)]] const uint SAMPLES_PER_RUN = 1;
[[vk::constant_id(1)]] const uint MAX_BOUNCES = 4;

RayDesc generateDir(Camera camera, float4 rand) {
    float2 sampled_rand = squareToUniformDiskConcentric(rand.xy);
    float2 rd = camera.lens_radius * sampled_rand;
    float3 defocusOffset = camera.u * rd.x + camera.v * rd.y;
    
    float2 randomCenter = float2(0.5, 0.5) + 0.5 * squareToGaussian(rand.zw);
    float2 uv = (float2(DispatchRaysIndex().xy) + randomCenter) / float2(DispatchRaysDimensions().xy);
    uv.y -= 1;
    uv.y *= -1;

    RayDesc rayDesc;
    rayDesc.Origin = camera.origin + defocusOffset;
    rayDesc.Direction = normalize(camera.lower_left_corner + uv.x * camera.horizontal + uv.y * camera.vertical - defocusOffset - camera.origin);
    rayDesc.TMin = 0.0001;
	rayDesc.TMax = 10000.0;

    return rayDesc;
}

float3 pathTrace(inout Rng rng, RayDesc initialRay) {
    float3 accumulatedColor = float3(0.0, 0.0, 0.0);

    RayDesc ray = initialRay;

    float3 throughput = float3(1.0, 1.0, 1.0);

    for (uint bounceCount = 0; bounceCount < MAX_BOUNCES; bounceCount++) {
        
        Payload payload;
        TraceRay(TLAS, RAY_FLAG_FORCE_OPAQUE, 0xFF, 0, 0, 0, ray, payload);
        if (!payload.done) {
            Material material = getMaterial(payload.materialIndex, payload.texcoord);
            
            Frame frame = createFrame(payload.normal);
            float3 outgoing = frame.worldToFrame(-ray.Direction);
            
            float4 rand1 = float4(rng.getFloat(), rng.getFloat(), rng.getFloat(), rng.getFloat());
            float3 lightSample1 = estimateBackgroundDirect(frame, outgoing, material, rand1, payload);
            float4 rand2 = float4(rng.getFloat(), rng.getFloat(), rng.getFloat(), rng.getFloat());
            float3 lightSample2 = estimateBackgroundDirect(frame, outgoing, material, rand2, payload);
            accumulatedColor += (throughput * (lightSample1 + lightSample2) / 2.0);
            
            // set up info for next bounce
            ray.Origin = payload.position;
            float pdf;
            float u = rng.getFloat();
            float v = rng.getFloat();
            float3 incoming = material.sample(outgoing, pdf, float2(u, v));
            if (!sameHemisphere(outgoing, incoming)) {
                break;
            }
            ray.Direction = frame.frameToWorld(incoming);
            throughput *= material.f_r(incoming, outgoing) * abs(frameCosTheta(incoming)) / pdf;
        } else {
            // no hit, we're done
            if (bounceCount == 0) {
                // if primary ray, add background
                accumulatedColor += throughput * getBackgroundColor(ray.Direction);
            }
            break;
        }
    }

    return accumulatedColor;
}

void storeColor(float3 color) {
    uint2 imageCoords = DispatchRaysIndex().xy;
    float3 previouslyAccumulated;
    if (pushConsts.numAccumulatedFrames == 0) {
        previouslyAccumulated = float3(0.0, 0.0, 0.0);
    } else {
        previouslyAccumulated = accumulationImage[imageCoords].rgb;
    }
    accumulationImage[imageCoords] = float4(previouslyAccumulated + color, 1.0);
    displayImage[imageCoords] = float4((previouslyAccumulated + color) / ((pushConsts.numAccumulatedFrames + 1) * SAMPLES_PER_RUN), 1.0);
}

[shader("raygeneration")]
void main() {
    Rng rng = InitRng((pushConsts.numAccumulatedFrames + 1) * DispatchRaysIndex().x * DispatchRaysIndex().x + DispatchRaysIndex().y);

    // the result that we write to our buffer
    float3 color = float3(0.0, 0.0, 0.0);

    for (uint sampleCount = 0; sampleCount < SAMPLES_PER_RUN; sampleCount++) {
        // set up initial directions for first bounce
        float4 rand = float4(rng.getFloat(), rng.getFloat(), rng.getFloat(), rng.getFloat());
        RayDesc initialRay = generateDir(pushConsts.camera, rand);

        color += pathTrace(rng, initialRay);
    }

    storeColor(color);
}
