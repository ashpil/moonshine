#pragma once

#include "../utils/math.hlsl"
#include "../utils/random.hlsl"
#include "reflection_frame.hlsl"
#include "material.hlsl"
#include "world.hlsl"
#include "light.hlsl"

float powerHeuristic(uint numf, float fPdf, uint numg, float gPdf) {
    float f = numf * fPdf;
    float g = numg * gPdf;

    float f2 = f * f;
    return (f2 / (f2 + g * g));
}

// estimates direct lighting from light + brdf via MIS
// only samples light
template <class Light, class Material>
float3 estimateDirectMISLight(RaytracingAccelerationStructure accel, Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 triangleNormalDirWs, float2 rand, uint samplesTaken) {
    LightSample lightSample = light.sample(accel, positionWs, triangleNormalDirWs, rand);

    if (lightSample.pdf > 0.0) {
        float3 lightDirFs = frame.worldToFrame(lightSample.dirWs);
        float scatteringPdf = material.pdf(lightDirFs, outgoingDirFs);
        if (scatteringPdf > 0.0) {
            float3 brdf = material.eval(lightDirFs, outgoingDirFs);
            float weight = powerHeuristic(samplesTaken, lightSample.pdf, 1, scatteringPdf);
            return lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) * weight / lightSample.pdf;
        }
    }

    return 0.0;
}

// no MIS, just light
template <class Light, class Material>
float3 estimateDirect(RaytracingAccelerationStructure accel, Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 normalDirWs, float2 rand) {
    LightSample lightSample = light.sample(accel, positionWs, normalDirWs, rand);
    float3 lightDirFs = frame.worldToFrame(lightSample.dirWs);

    if (lightSample.pdf > 0.0) {
        float3 brdf = material.eval(lightDirFs, outgoingDirFs);
        return lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) / lightSample.pdf;
    } else {
        return float3(0, 0, 0);
    }
}

interface Integrator {
    float3 incomingRadiance(Scene scene, RayDesc ray, inout Rng rng);
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

    float3 incomingRadiance(Scene scene, RayDesc initialRay, inout Rng rng) {
        float3 accumulatedColor = float3(0.0, 0.0, 0.0);

        // state updated at each bounce
        RayDesc ray = initialRay;
        float3 throughput = float3(1.0, 1.0, 1.0);
        uint bounceCount = 0;
        float lastMaterialPdf;
        bool isLastMaterialDelta = false;

        // main path tracing loop
        for (Intersection its = Intersection::find(scene.tlas, ray); its.hit(); its = Intersection::find(scene.tlas, ray)) {

            // decode mesh attributes and material from intersection
            uint instanceID = scene.world.instances[its.instanceIndex].instanceID();
            Geometry geometry = scene.world.getGeometry(instanceID, its.geometryIndex);
            MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(scene.world, its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.barycentrics).inWorld(scene.world, its.instanceIndex);
            Frame textureFrame = getTextureFrame(scene.world, scene.world.materialIdx(instanceID, its.geometryIndex), attrs.texcoord, attrs.frame);
            float3 emissiveLight = getEmissive(scene.world, scene.world.materialIdx(instanceID, its.geometryIndex), attrs.texcoord);
            MaterialVariantData materialData = scene.world.materials[NonUniformResourceIndex(scene.world.materialIdx(instanceID, its.geometryIndex))];
            MaterialVariant material = MaterialVariant::load(materialData.type, materialData.materialAddress, attrs.texcoord);

            float3 outgoingDirWs = -ray.Direction;

            // select proper shading normal
            bool frontfacing = dot(attrs.triangleFrame.n, outgoingDirWs) > 0;
            Frame shadingFrame;
            if ((frontfacing && dot(outgoingDirWs, textureFrame.n) > 0) || (!frontfacing && -dot(outgoingDirWs, textureFrame.n) > 0)) {
                // prefer texture normal if we can
                shadingFrame = textureFrame;
            } else if ((frontfacing && dot(outgoingDirWs, attrs.frame.n) > 0) || (!frontfacing && -dot(outgoingDirWs, attrs.frame.n) > 0)) {
                // if texture normal not valid, try shading normal
                shadingFrame = attrs.frame;
            } else {
                // otherwise fall back to triangle normal
                shadingFrame = attrs.triangleFrame;
            }

            float3 outgoingDirSs = shadingFrame.worldToFrame(outgoingDirWs);

            // collect light from emissive meshes
            if (mesh_samples_per_bounce == 0 || bounceCount == 0 || !geometry.sampled || isLastMaterialDelta) {
                // add emissive light at point if light not explicitly sampled or initial bounce
                if (dot(outgoingDirWs, attrs.triangleFrame.n) > 0.0) {
                    // lights only emit from front face
                    accumulatedColor += throughput * emissiveLight;
                }
            } else if (geometry.sampled) {
                // MIS emissive light if it is sampled at later bounces
                float sum = scene.meshLights.aliasTable[0].select;
                float lightPdf = areaMeasureToSolidAngleMeasure(attrs.position, ray.Origin, ray.Direction, attrs.triangleFrame.n) / sum;

                if (lightPdf > 0.0) {
                    float weight = powerHeuristic(1, lastMaterialPdf, mesh_samples_per_bounce, lightPdf);
                    accumulatedColor += throughput * emissiveLight * weight;
                }
            }

            bool isCurrentMaterialDelta = material.isDelta();

            if (!isCurrentMaterialDelta) {
                // accumulate direct light samples from env map
                for (uint directCount = 0; directCount < env_samples_per_bounce; directCount++) {
                    float2 rand = float2(rng.getFloat(), rng.getFloat());
                    accumulatedColor += throughput * estimateDirectMISLight(scene.tlas, shadingFrame, scene.envMap, material, outgoingDirSs, attrs.position, attrs.triangleFrame.n, rand, env_samples_per_bounce) / env_samples_per_bounce;
                }

                // accumulate direct light samples from emissive meshes
                for (uint directCount = 0; directCount < mesh_samples_per_bounce; directCount++) {
                    float2 rand = float2(rng.getFloat(), rng.getFloat());
                    accumulatedColor += throughput * estimateDirectMISLight(scene.tlas, shadingFrame, scene.meshLights, material, outgoingDirSs, attrs.position, attrs.triangleFrame.n, rand, mesh_samples_per_bounce) / mesh_samples_per_bounce;
                }
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
            isLastMaterialDelta = isCurrentMaterialDelta;
        }

        // we only get here on misses -- terminations for other reasons return from loop

        // handle env map
        if (env_samples_per_bounce == 0 || bounceCount == 0 || isLastMaterialDelta) {
            // add background color if it isn't explicitly sampled or this is a primary ray
            accumulatedColor += throughput * scene.envMap.incomingRadiance(ray.Direction);
        } else {
            // MIS env map if it is sampled at later bounces
            LightEval l = scene.envMap.eval(ray.Direction);

            if (l.pdf > 0.0) {
                float weight = powerHeuristic(1, lastMaterialPdf, env_samples_per_bounce, l.pdf);
                accumulatedColor += throughput * l.radiance * weight;
            }
        }

        return accumulatedColor;
    }
};

// primary ray + light sample
// same as above with max_bounces = 0, but simpler code
struct DirectLightIntegrator : Integrator {
    uint env_samples_per_bounce;
    uint mesh_samples_per_bounce;

    static DirectLightIntegrator create(uint env_samples_per_bounce, uint mesh_samples_per_bounce) {
        DirectLightIntegrator integrator;
        integrator.env_samples_per_bounce = env_samples_per_bounce;
        integrator.mesh_samples_per_bounce = mesh_samples_per_bounce;
        return integrator;
    }

    float3 incomingRadiance(Scene scene, RayDesc initialRay, inout Rng rng) {
        float3 accumulatedColor = float3(0.0, 0.0, 0.0);

        Intersection its = Intersection::find(scene.tlas, initialRay);
        if (its.hit()) {
            // decode mesh attributes and material from intersection
            uint instanceID = scene.world.instances[its.instanceIndex].instanceID();
            Geometry geometry = scene.world.getGeometry(instanceID, its.geometryIndex);
            MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(scene.world, its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.barycentrics).inWorld(scene.world, its.instanceIndex);
            Frame textureFrame = getTextureFrame(scene.world, scene.world.materialIdx(instanceID, its.geometryIndex), attrs.texcoord, attrs.frame);
            StandardPBR material = StandardPBR::load(scene.world.materials[NonUniformResourceIndex(scene.world.materialIdx(instanceID, its.geometryIndex))].materialAddress, attrs.texcoord);

            float3 outgoingDirWs = -initialRay.Direction;

            // select proper shading normal
            Frame shadingFrame;
            if (dot(outgoingDirWs, textureFrame.n) > 0) {
                // prefer texture normal if we can
                shadingFrame = textureFrame;
            } else if (dot(outgoingDirWs, attrs.frame.n) > 0) {
                // if texture normal not valid, try shading normal
                shadingFrame = attrs.frame;
            } else {
                // otherwise fall back to triangle normal
                shadingFrame = attrs.triangleFrame;
            }

            float3 outgoingDirSs = shadingFrame.worldToFrame(outgoingDirWs);

            // collect light from emissive meshes
            accumulatedColor += getEmissive(scene.world, scene.world.materialIdx(instanceID, its.geometryIndex), attrs.texcoord);

            // accumulate direct light samples from env map
            for (uint directCount = 0; directCount < env_samples_per_bounce; directCount++) {
                float2 rand = float2(rng.getFloat(), rng.getFloat());
                accumulatedColor += estimateDirectMISLight(scene.tlas, shadingFrame, scene.envMap, material, outgoingDirSs, attrs.position, attrs.triangleFrame.n, rand, env_samples_per_bounce) / env_samples_per_bounce;
            }

            // accumulate direct light samples from emissive meshes
            for (uint directCount = 0; directCount < mesh_samples_per_bounce; directCount++) {
                float2 rand = float2(rng.getFloat(), rng.getFloat());
                accumulatedColor += estimateDirectMISLight(scene.tlas, shadingFrame, scene.meshLights, material, outgoingDirSs, attrs.position, attrs.triangleFrame.n, rand, mesh_samples_per_bounce) / mesh_samples_per_bounce;
            }
        } else {
            // add background color
            accumulatedColor += scene.envMap.incomingRadiance(initialRay.Direction);
        }

        return accumulatedColor;
    }
};
