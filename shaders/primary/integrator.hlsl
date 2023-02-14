#include "math.hlsl"
#include "reflection_frame.hlsl"
#include "random.hlsl"
#include "material.hlsl"
#include "geometry.hlsl"
#include "light.hlsl"

interface Integrator {
    float3 incomingRadiance(RayDesc ray, inout Rng rng);
};

struct PathTracingIntegrator : Integrator {
    uint max_bounces;
    uint env_samples_per_bounce;
    uint mesh_samples_per_bounce;

    static PathTracingIntegrator create(uint max_bounces, uint env_samples_per_bounce, uint mesh_samples_per_bounce) {
        PathTracingIntegrator integrator;
        integrator.max_bounces = max_bounces;
        integrator.env_samples_per_bounce = env_samples_per_bounce;
        integrator.mesh_samples_per_bounce = mesh_samples_per_bounce;
        return integrator;
    }

    float3 incomingRadiance(RayDesc initialRay, inout Rng rng) {
        float3 accumulatedColor = float3(0.0, 0.0, 0.0);

        // state updated at each bounce
        RayDesc ray = initialRay;
        float3 throughput = float3(1.0, 1.0, 1.0);
        uint bounceCount = 0;
        float lastMaterialPdf;

        // main path tracing loop
        for (Intersection its = Intersection::find(ray); its.hit(); its = Intersection::find(ray)) {

            // decode mesh attributes and material from intersection
            uint instanceID = dInstances[its.instanceIndex].instanceID();
            Geometry geometry = getGeometry(instanceID, its.geometryIndex);
            MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.attribs).inWorld(its.instanceIndex);
            MaterialParameters materialParams = MaterialParameters::create(materialIdx(instanceID, its.geometryIndex), attrs.texcoord, attrs.frame);
            StandardPBR material = materialParams.getStandardPBR();

            float3 outgoingDirWs = -ray.Direction;

            // select proper shading normal
            Frame shadingFrame;
            if (dot(outgoingDirWs, materialParams.frame.n) > 0) {
                // prefer texture normal if we can
                shadingFrame = materialParams.frame;
            } else if (dot(outgoingDirWs, attrs.frame.n) > 0) {
                // if texture normal not valid, try shading normal
                shadingFrame = attrs.frame;
            } else {
                // otherwise fall back to triangle normal
                shadingFrame = attrs.triangleFrame;
            }

            float3 outgoingDirSs = shadingFrame.worldToFrame(outgoingDirWs);

            // collect light from emissive meshes
            if (mesh_samples_per_bounce == 0 || bounceCount == 0 || !geometry.sampled) {
                // add emissive light at point if light not explicitly sampled or initial bounce
                accumulatedColor += throughput * materialParams.emissive;
            } else if (geometry.sampled) {
                // MIS emissive light if it is sampled at later bounces
                float lightPdf;
                {
                    float3 samplePositionToEmitterPositionWs = attrs.position - ray.Origin;
                    float r2 = dot(samplePositionToEmitterPositionWs, samplePositionToEmitterPositionWs);
                    float sum = dEmitterAliasTable[0].select;
                    lightPdf = r2 / (abs(Frame::cosTheta(outgoingDirSs)) * sum);
                }

                if (lightPdf > 0.0) {
                    float weight = powerHeuristic(1, lastMaterialPdf, mesh_samples_per_bounce, lightPdf);
                    accumulatedColor += throughput * materialParams.emissive * weight;
                }
            }

            // accumulate direct light samples from env map
            for (uint directCount = 0; directCount < env_samples_per_bounce; directCount++) {
                float2 rand = float2(rng.getFloat(), rng.getFloat());
                accumulatedColor += throughput * estimateDirectMISLight(shadingFrame, EnvMap::create(), material, outgoingDirSs, attrs.position, attrs.triangleFrame.n, rand, env_samples_per_bounce) / env_samples_per_bounce;
            }

            // accumulate direct light samples from emissive meshes
            for (uint directCount = 0; directCount < mesh_samples_per_bounce; directCount++) {
                float2 rand = float2(rng.getFloat(), rng.getFloat());
                accumulatedColor += throughput * estimateDirectMISLight(shadingFrame, MeshLights::create(), material, outgoingDirSs, attrs.position, attrs.triangleFrame.n, rand, mesh_samples_per_bounce) / mesh_samples_per_bounce;
            }

            // possibly terminate if reached max bounce cutoff or lose at russian roulette
            if (bounceCount >= max_bounces) {
                return accumulatedColor;
            } else if (bounceCount > 3) {
                // russian roulette
                float pSurvive = min(0.95, luminance(throughput));
                if (rng.getFloat() > pSurvive) return accumulatedColor;
                throughput /= pSurvive;
            }
            
            // sample direction for next bounce
            MaterialSample sample = material.sample(outgoingDirSs, float2(rng.getFloat(), rng.getFloat()));
            if (sample.pdf == 0.0) return accumulatedColor;
            lastMaterialPdf = sample.pdf;

            // set up info for next bounce
            ray.Direction = shadingFrame.frameToWorld(sample.dirFs);
            ray.Origin = offsetAlongNormal(attrs.position, faceForward(attrs.triangleFrame.n, ray.Direction));
            throughput *= material.eval(sample.dirFs, outgoingDirSs) * abs(Frame::cosTheta(sample.dirFs)) / sample.pdf;
            bounceCount += 1;
        }

        // we only get here on misses -- terminations for other reasons return from loop

        // handle env map
        if (env_samples_per_bounce == 0 || bounceCount == 0) {
            // add background color if it isn't explicitly sampled or this is a primary ray
            accumulatedColor += throughput * EnvMap::create().incomingRadiance(ray.Direction);
        } else {
            // MIS env map if it is sampled at later bounces
            float lightPdf;
            {
                float2 phiTheta = cartesianToSpherical(ray.Direction);
                float2 uv = phiTheta / float2(2 * PI, PI);

                uint2 size;
                dBackgroundTexture.GetDimensions(size.x, size.y);
                uint2 coords = clamp(uint2(uv * size), uint2(0, 0), size);
                float pdf2d = dBackgroundMarginalAlias[coords.y].data * dBackgroundConditionalAlias[coords.y * size.x + coords.x].data * size.x * size.y;
                float sinTheta = sin(phiTheta.y);
                lightPdf = sinTheta != 0.0 ? pdf2d / (2.0 * PI * PI * sin(phiTheta.y)) : 0.0;
            }

            if (lightPdf > 0.0) {
                float weight = powerHeuristic(1, lastMaterialPdf, env_samples_per_bounce, lightPdf);
                accumulatedColor += throughput * EnvMap::create().incomingRadiance(ray.Direction) * weight;
            }
        }

        return accumulatedColor;
    }
};

