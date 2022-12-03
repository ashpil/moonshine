// set 0 - scene
// set 1 - background
// set 2 - display

// geometry
[[vk::binding(0, 0)]] RaytracingAccelerationStructure TLAS;

// display
[[vk::binding(0, 2)]] RWTexture2D<float4> displayImage;
[[vk::binding(1, 2)]] RWTexture2D<float4> accumulationImage;

#include "math.hlsl"
#include "payload.hlsl"
#include "reflection_frame.hlsl"
#include "random.hlsl"
#include "material.hlsl"
#include "light.hlsl"
#include "geometry.hlsl"

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
[[vk::constant_id(2)]] const uint DIRECT_SAMPLES_PER_BOUNCE = 2;

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

float3 pathTrace(EnvMap background, RayDesc initialRay, inout Rng rng) {
    float3 accumulatedColor = float3(0.0, 0.0, 0.0);

    RayDesc ray = initialRay;

    float3 throughput = float3(1.0, 1.0, 1.0);

    for (uint bounceCount = 0; bounceCount < MAX_BOUNCES; bounceCount++) {
        
        Payload payload;
        TraceRay(TLAS, RAY_FLAG_FORCE_OPAQUE, 0xFF, 0, 0, 0, ray, payload);
        if (!payload.done()) {
            MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(meshIdx(payload.instanceID, payload.geometryIndex), payload.primitiveIndex, payload.attribs);
            attrs = attrs.inWorld(payload.instanceIndex);
   
            StandardPBR material = getMaterial(materialIdx(payload.instanceID, payload.geometryIndex), attrs.texcoord, attrs.normal, attrs.tangent, attrs.bitangent);
            accumulatedColor += throughput * material.emissive;

            Frame frame = Frame::create(material.normal);
            float3 outgoing = frame.worldToFrame(-ray.Direction);

            // accumulate direct light samples
            for (uint directCount = 0; directCount < DIRECT_SAMPLES_PER_BOUNCE; directCount++) {
                float4 rand = float4(rng.getFloat(), rng.getFloat(), rng.getFloat(), rng.getFloat());
                accumulatedColor += throughput * estimateDirect(frame, background, material, outgoing, attrs.position, attrs.normal, rand) / DIRECT_SAMPLES_PER_BOUNCE;
            }
            
            // set up info for next bounce
            ray.Origin = attrs.position;
            MaterialSample sample = material.sample(outgoing, float2(rng.getFloat(), rng.getFloat()));
            float3 incoming = sample.dirFs;
            ray.Direction = frame.frameToWorld(incoming);
            if (dot(attrs.normal, ray.Direction) <= 0.0 || sample.pdf == 0.0) break;
            throughput *= material.eval(incoming, outgoing) * abs(Frame::cosTheta(incoming)) / sample.pdf;

            // russian roulette
            if (bounceCount > 3) {
                float pSurvive = min(0.95, luminance(throughput));
                if (rng.getFloat() > pSurvive) break;
                throughput /= pSurvive;
            }
        } else {
            // no hit, we're done
            if (DIRECT_SAMPLES_PER_BOUNCE == 0 || bounceCount == 0) {
                // add background color if it isn't explicitly sampled or this is a primary ray
                accumulatedColor += throughput * background.eval(float3(0, 0, 0), ray.Direction);
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
    EnvMap background = EnvMap::create();

    // the result that we write to our buffer
    float3 color = float3(0.0, 0.0, 0.0);

    for (uint sampleCount = 0; sampleCount < SAMPLES_PER_RUN; sampleCount++) {
        // set up initial directions for first bounce
        float4 rand = float4(rng.getFloat(), rng.getFloat(), rng.getFloat(), rng.getFloat());
        RayDesc initialRay = generateDir(pushConsts.camera, rand);

        color += pathTrace(background, initialRay, rng);
    }

    storeColor(color);
}
