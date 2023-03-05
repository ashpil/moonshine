#include "math.hlsl"
#include "reflection_frame.hlsl"
#include "random.hlsl"
#include "material.hlsl"
#include "geometry.hlsl"
#include "light.hlsl"

float powerHeuristic(uint numf, float fPdf, uint numg, float gPdf) {
    float f = numf * fPdf;
    float g = numg * gPdf;

    float f2 = f * f;
    return (f2 / (f2 + g * g));
}

// estimates direct lighting from light + brdf via MIS
// samples light and material
template <class Light, class Material>
float3 estimateDirectMISLightMaterial(Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 triangleNormalDirWs, float4 rand) {
    float3 directLighting = float3(0.0, 0.0, 0.0);

    // sample light
    {
        LightSample lightSample = light.sample(positionWs, triangleNormalDirWs, rand.xy);

        if (lightSample.pdf > 0.0) {
            float3 lightDirFs = frame.worldToFrame(lightSample.dirWs);
            float scatteringPdf = material.pdf(lightDirFs, outgoingDirFs);
            if (scatteringPdf > 0.0) {
                float3 brdf = material.eval(lightDirFs, outgoingDirFs);
                float weight = powerHeuristic(1, lightSample.pdf, 1, scatteringPdf);
                directLighting += lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) * weight / lightSample.pdf;
            }
        }
    }

    // sample material
    {
        MaterialSample materialSample = material.sample(outgoingDirFs, rand.zw);

        if (materialSample.pdf > 0.0) {
            float3 brdfDirWs = frame.frameToWorld(materialSample.dirFs);
            LightEval lightContrib = light.eval(positionWs, triangleNormalDirWs, brdfDirWs);
            if (lightContrib.pdf > 0.0) {
                float3 brdf = material.eval(materialSample.dirFs, outgoingDirFs);
                float weight = powerHeuristic(1, materialSample.pdf, 1, lightContrib.pdf);
                directLighting += lightContrib.radiance * brdf * abs(Frame::cosTheta(materialSample.dirFs)) * weight / materialSample.pdf;
            }
        }
    }

    return directLighting;
}

// estimates direct lighting from light + brdf via MIS
// only samples light
template <class Light, class Material>
float3 estimateDirectMISLight(Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 triangleNormalDirWs, float2 rand, uint samplesTaken) {
    LightSample lightSample = light.sample(positionWs, triangleNormalDirWs, rand);

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
float3 estimateDirect(Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 normalDirWs, float2 rand) {
    LightSample lightSample = light.sample(positionWs, normalDirWs, rand);
    float3 lightDirFs = frame.worldToFrame(lightSample.dirWs);

    if (lightSample.pdf > 0.0) {
        float3 brdf = material.eval(lightDirFs, outgoingDirFs);
        return lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) / lightSample.pdf;
    } else {
        return float3(0, 0, 0);
    }
}

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
        bool isLastMaterialDelta = false;

        // main path tracing loop
        for (Intersection its = Intersection::find(ray); its.hit(); its = Intersection::find(ray)) {

            // decode mesh attributes and material from intersection
            uint instanceID = dInstances[its.instanceIndex].instanceID();
            Geometry geometry = getGeometry(instanceID, its.geometryIndex);
            MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.attribs).inWorld(its.instanceIndex);
            Frame textureFrame = getTextureFrame(materialIdx(instanceID, its.geometryIndex), attrs.texcoord, attrs.frame);
            float3 emissiveLight = getEmissive(materialIdx(instanceID, its.geometryIndex), attrs.texcoord);
            AnyMaterialData materialData = dMaterials[NonUniformResourceIndex(materialIdx(instanceID, its.geometryIndex))];
            AnyMaterial material = AnyMaterial::load(materialData.type, materialData.materialAddress, attrs.texcoord);

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
                float lightPdf;
                {
                    float3 samplePositionToEmitterPositionWs = attrs.position - ray.Origin;
                    float r2 = dot(samplePositionToEmitterPositionWs, samplePositionToEmitterPositionWs);
                    float sum = dEmitterAliasTable[0].select;
                    float lightCos = dot(outgoingDirWs, attrs.triangleFrame.n);
                    if (lightCos > 0.0) {
                        lightPdf = r2 / (lightCos * sum);
                    } else {
                        lightPdf = 0.0;
                    }
                }

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
                    accumulatedColor += throughput * estimateDirectMISLight(shadingFrame, EnvMap::create(), material, outgoingDirSs, attrs.position, attrs.triangleFrame.n, rand, env_samples_per_bounce) / env_samples_per_bounce;
                }

                // accumulate direct light samples from emissive meshes
                for (uint directCount = 0; directCount < mesh_samples_per_bounce; directCount++) {
                    float2 rand = float2(rng.getFloat(), rng.getFloat());
                    accumulatedColor += throughput * estimateDirectMISLight(shadingFrame, MeshLights::create(), material, outgoingDirSs, attrs.position, attrs.triangleFrame.n, rand, mesh_samples_per_bounce) / mesh_samples_per_bounce;
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

    float3 incomingRadiance(RayDesc initialRay, inout Rng rng) {
        float3 accumulatedColor = float3(0.0, 0.0, 0.0);

        Intersection its = Intersection::find(initialRay);
        if (its.hit()) {
            // decode mesh attributes and material from intersection
            uint instanceID = dInstances[its.instanceIndex].instanceID();
            Geometry geometry = getGeometry(instanceID, its.geometryIndex);
            MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.attribs).inWorld(its.instanceIndex);
            Frame textureFrame = getTextureFrame(materialIdx(instanceID, its.geometryIndex), attrs.texcoord, attrs.frame);
            StandardPBR material = StandardPBR::load(dMaterials[NonUniformResourceIndex(materialIdx(instanceID, its.geometryIndex))].materialAddress, attrs.texcoord);

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
            accumulatedColor += getEmissive(materialIdx(instanceID, its.geometryIndex), attrs.texcoord);

            // accumulate direct light samples from env map
            for (uint directCount = 0; directCount < env_samples_per_bounce; directCount++) {
                float2 rand = float2(rng.getFloat(), rng.getFloat());
                accumulatedColor += estimateDirectMISLight(shadingFrame, EnvMap::create(), material, outgoingDirSs, attrs.position, attrs.triangleFrame.n, rand, env_samples_per_bounce) / env_samples_per_bounce;
            }

            // accumulate direct light samples from emissive meshes
            for (uint directCount = 0; directCount < mesh_samples_per_bounce; directCount++) {
                float2 rand = float2(rng.getFloat(), rng.getFloat());
                accumulatedColor += estimateDirectMISLight(shadingFrame, MeshLights::create(), material, outgoingDirSs, attrs.position, attrs.triangleFrame.n, rand, mesh_samples_per_bounce) / mesh_samples_per_bounce;
            }
        } else {
            // add background color
            accumulatedColor += EnvMap::create().incomingRadiance(initialRay.Direction);
        }

        return accumulatedColor;
    }
};
