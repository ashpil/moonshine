#include "math.hlsl"
#include "reflection_frame.hlsl"
#include "random.hlsl"
#include "material.hlsl"
#include "light.hlsl"
#include "geometry.hlsl"

Intersection intersectScene(RayDesc ray) {
    Intersection its;
    TraceRay(dTLAS, RAY_FLAG_FORCE_OPAQUE, 0xFF, 0, 0, 0, ray, its);
    return its;
}

interface Integrator {
    float3 incomingRadiance(RayDesc ray, inout Rng rng);
};

struct PathTracingIntegrator {
    uint max_bounces;
    uint direct_samples_per_bounce;

    static PathTracingIntegrator create(uint max_bounces, uint direct_samples_per_bounce) {
        PathTracingIntegrator integrator;
        integrator.max_bounces = max_bounces;
        integrator.direct_samples_per_bounce = direct_samples_per_bounce;
        return integrator;
    }

    float3 incomingRadiance(RayDesc initialRay, inout Rng rng) {
        float3 accumulatedColor = float3(0.0, 0.0, 0.0);

        // state updated at each bounce
        RayDesc ray = initialRay;
        float3 throughput = float3(1.0, 1.0, 1.0);
        uint bounceCount = 0;
        Intersection its = intersectScene(ray);

        // main path tracing loop
        while (its.hit()) {
            bounceCount += 1;

            // decode mesh attributes and material from intersection
            MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(meshIdx(its.instanceID, its.geometryIndex), its.primitiveIndex, its.attribs).inWorld(its.instanceIndex);
            StandardPBR material = getMaterial(materialIdx(its.instanceID, its.geometryIndex), attrs.texcoord, attrs.normal, attrs.tangent, attrs.bitangent);

            // add emissive light at point
            accumulatedColor += throughput * material.emissive;

            // create local shading frame
            Frame frame = Frame::create(material.normal);
            float3 outgoing = frame.worldToFrame(-ray.Direction);

            // accumulate direct light samples
            for (uint directCount = 0; directCount < direct_samples_per_bounce; directCount++) {
                float4 rand = float4(rng.getFloat(), rng.getFloat(), rng.getFloat(), rng.getFloat());
                accumulatedColor += throughput * estimateDirect(frame, EnvMap::create(), material, outgoing, attrs.position, attrs.normal, rand) / direct_samples_per_bounce;
            }

            // possibly terminate if reached max bounce cutoff or lose at russian roulette
            if (bounceCount >= max_bounces) {
                break;
            } else if (bounceCount > 3) {
                // russian roulette
                float pSurvive = min(0.95, luminance(throughput));
                if (rng.getFloat() > pSurvive) break;
                throughput /= pSurvive;
            }
            
            // sample direction for next bounce
            MaterialSample sample = material.sample(outgoing, float2(rng.getFloat(), rng.getFloat()));

            // set up info for next bounce
            ray.Direction = frame.frameToWorld(sample.dirFs);
            ray.Origin = attrs.position;
            if (dot(attrs.normal, ray.Direction) <= 0.0 || sample.pdf == 0.0) break;
            throughput *= material.eval(sample.dirFs, outgoing) * abs(Frame::cosTheta(sample.dirFs)) / sample.pdf;
            its = intersectScene(ray);
        }

        // add background color if it isn't explicitly sampled or this is a primary ray
        if (direct_samples_per_bounce == 0 || bounceCount == 0) {
            accumulatedColor += throughput * EnvMap::create().eval(float3(0, 0, 0), ray.Direction);
        }

        return accumulatedColor;
    }
};

