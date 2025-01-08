#pragma once

#include "../utils/math.hlsl"
#include "../utils/random.hlsl"
#include "material.hlsl"
#include "medium.hlsl"
#include "phase_function.hlsl"
#include "world.hlsl"
#include "light.hlsl"
#include "ray.hlsl"
#include "spectrum.hlsl"

// with
//   power == 1 this becomes balance heuristic
//   power == 0 this becomes uniform weighting
float powerHeuristic(const uint fCount, const float fPdf, const uint gCount, const float gPdf, const uint power) {
    return pow(fPdf, power) / (fCount * pow(fPdf, power) + gCount * pow(gPdf, power));
}

float misWeight(const uint fCount, const float fPdf, const uint gCount, const float gPdf) {
    if (fPdf == 1.#INF) return 1.0 / fCount; // delta distribution for f, g not relevant
    return powerHeuristic(fCount, fPdf, gCount, gPdf, 2);
}

// estimates direct lighting from light + brdf via MIS
// only samples light
template <class Light, class BSDF>
float estimateDirect(RaytracingAccelerationStructure accel, Light light, BSDF material, float3 outgoingDirWs, float λ, float3 positionWs, float3 triangleNormalDirWs, float spawnOffset, float2 rand, uint lightSamplesTaken, uint brdfSamplesTaken) {
    const LightSample lightSample = light.sample(λ, positionWs, rand);

    if (lightSample.eval.radiance != 0) {
        const BSDFEvaluation bsdfEval = material.evaluate(lightSample.dirWs, outgoingDirWs);
        if (bsdfEval.attenuation != 0) {
            const float weight = misWeight(lightSamplesTaken, lightSample.eval.pdf, brdfSamplesTaken, bsdfEval.pdf);
            const float totalRadiance = lightSample.eval.radiance * bsdfEval.attenuation * weight;

            const Ray ray = {positionWs + faceForward(triangleNormalDirWs, lightSample.dirWs) * spawnOffset, lightSample.dirWs};
            if (!ShadowIntersection::hit(accel, ray, lightSample.distance - dot(lightSample.dirWs, faceForward(triangleNormalDirWs, lightSample.dirWs) * spawnOffset))) {
                return totalRadiance;
            }
        }
    }

    return 0;
}

// estimates direct lighting from light + brdf via MIS
// only samples light
// separate function for volumes as we need to find the closest hit, not just terminate on any hit
template <class Light, class BSDF>
float estimateDirectVolumetric(World world, RaytracingAccelerationStructure accel, Light light, BSDF material, float3 outgoingDirWs, float λ, float3 positionWs, float3 triangleNormalDirWs, float spawnOffset, Volume interior, Volume global, float2 rand, uint lightSamplesTaken, uint brdfSamplesTaken) {
    const LightSample lightSample = light.sample(λ, positionWs, rand);

    if (lightSample.eval.radiance != 0) {
        const BSDFEvaluation bsdfEval = material.evaluate(lightSample.dirWs, outgoingDirWs);
        if (bsdfEval.attenuation != 0) {
            const float weight = misWeight(lightSamplesTaken, lightSample.eval.pdf, brdfSamplesTaken, bsdfEval.pdf);
            const float totalRadiance = lightSample.eval.radiance * bsdfEval.attenuation * weight;

            Ray ray = {positionWs + faceForward(triangleNormalDirWs, lightSample.dirWs) * spawnOffset, lightSample.dirWs};
            float throughput = 1;
            float remainingDistance = lightSample.distance - dot(lightSample.dirWs, faceForward(triangleNormalDirWs, lightSample.dirWs) * spawnOffset);
            const bool inside = dot(lightSample.dirWs, triangleNormalDirWs) <= 0;
            Volume volume;
            if (inside) {
                volume = interior;
            } else {
                volume = global;
            }
            // trace rays, going through all index-matched media
            // TODO: might be able to do this in a short-circuiting way somehow, as we can terminate early if we find any opaque object
            for (Intersection its = Intersection::find(accel, ray, remainingDistance); its.hit(); its = Intersection::find(accel, ray, remainingDistance)) {
                const Material material = world.material(its.instanceIndex, its.geometryIndex);
                if (material.isIndexMatched(λ, global.IOR)) {
                    const SurfacePoint surface = world.surfacePoint(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.barycentrics);

                    // attenuate throughput
                    const float tHit = distance(ray.origin, surface.position);
                    throughput *= volume.medium.transmittance(tHit);

                    // update state for next iteration
                    const bool entering = dot(ray.direction, surface.triangleFrame.n) <= 0;
                    if (entering) {
                        volume = material.volume.at(λ);
                    } else {
                        volume = global;
                    }
                    ray.origin = surface.position + faceForward(surface.triangleFrame.n, ray.direction) * surface.spawnOffset;
                    remainingDistance = remainingDistance - tHit + dot(ray.direction, faceForward(surface.triangleFrame.n, -ray.direction) * surface.spawnOffset);
                } else {
                    return 0;
                }
            }
            throughput *= volume.medium.transmittance(remainingDistance);
            return totalRadiance * throughput;
        }
    }

    return 0;
}

// selects a shading normal based on the most preferred normal that is plausible
Frame selectFrame(const SurfacePoint surface, const Material material, const float3 outgoingDirWs) {
    const Frame textureFrame = material.getTextureFrame(surface.texcoord, surface.frame);
    Frame shadingFrame;
    if (sign(dot(surface.triangleFrame.n, outgoingDirWs)) == sign(dot(outgoingDirWs, textureFrame.n))) {
        // prefer texture normal if we can
        shadingFrame = textureFrame;
    } else if (sign(dot(surface.triangleFrame.n, outgoingDirWs)) == sign(dot(outgoingDirWs, surface.frame.n))) {
        // if texture normal not valid, try shading normal
        shadingFrame = surface.frame;
    } else {
        // otherwise fall back to triangle normal
        shadingFrame = surface.triangleFrame;
    }

    return shadingFrame;
}

struct Path {
    Ray ray;
    float throughput;
    float radiance;
    float pdf;
    uint bounceCount;
    Volume volume;

    static Path create(const Ray ray, const Volume volume) {
        Path p;
        p.ray = ray;
        p.throughput = 1;
        p.radiance = 0;
        p.pdf = 1.#INF; // assume initial event was delta
        p.bounceCount = 0;
        p.volume = volume;
        return p;
    }

    static Path create(const Ray ray, const float IOR) {
        return Path::create(ray, Volume::transparent(IOR));
    }
};

interface Integrator {
    float incomingRadiance(const Scene scene, const Ray initialRay, const float λ, inout Rng rng);
};

// TODO:
// * support nested/overlapping media
// * don't assume original ray starts in global medium
struct VolumePathTracingIntegrator : Integrator {
    uint russianRouletteDepth;
    uint envSamplesPerBounce;
    uint meshSamplesPerBounce;

    static VolumePathTracingIntegrator create(uint russianRouletteDepth, uint envSamplesPerBounce, uint meshSamplesPerBounce) {
        VolumePathTracingIntegrator integrator;
        integrator.russianRouletteDepth = russianRouletteDepth;
        integrator.envSamplesPerBounce = envSamplesPerBounce;
        integrator.meshSamplesPerBounce = meshSamplesPerBounce;
        return integrator;
    }

    float incomingRadiance(const Scene scene, const Ray initialRay, const float λ, inout Rng rng) {
        const Volume globalVolume = scene.globalVolume.at(λ);
        Path path = Path::create(initialRay, globalVolume);
        while (true) {
            const float mediumTMax = path.volume.medium.sample(rng.getFloat());
            const Intersection its = Intersection::find(scene.tlas, path.ray, mediumTMax);
            if (its.hit()) {
                const float3 outgoingDirWs = -path.ray.direction;

                // decode mesh attributes and material from intersection
                const SurfacePoint surface = scene.world.surfacePoint(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.barycentrics);
                const Material material = scene.world.material(its.instanceIndex, its.geometryIndex);
                const Volume interiorVolume = material.volume.at(λ);
                const PolymorphicBSDF bsdf = PolymorphicBSDF::load(material, globalVolume.IOR, surface.texcoord, selectFrame(surface, material, outgoingDirWs), surface.triangleFrame, λ);

                // attenuate throughput by transmittance, divided by P(t > tHit)
                {
                    const float tHit = distance(path.ray.origin, surface.position);
                    const float pMoreThanT = path.volume.medium.transmittance(tHit);
                    const float transmittance = path.volume.medium.transmittance(tHit);
                    path.throughput *= transmittance / pMoreThanT;
                }

                // collect light from emissive meshes
                {
                    const float lightPdf = areaMeasureToSolidAngleMeasure(surface.position, path.ray.origin, path.ray.direction, surface.triangleFrame.n) * scene.meshLights.areaPdf(its.instanceIndex, its.geometryIndex, its.primitiveIndex);
                    const float weight = misWeight(1, path.pdf, meshSamplesPerBounce, lightPdf);
                    path.radiance += path.throughput * material.getEmissive(λ, surface.texcoord) * weight;
                }

                // accumulate direct light samples
                if (!bsdf.isDelta()) {
                    for (uint directCount = 0; directCount < envSamplesPerBounce; directCount++) {
                        float2 rand = float2(rng.getFloat(), rng.getFloat());
                        path.radiance += path.throughput * estimateDirectVolumetric(scene.world, scene.tlas, scene.envMap, bsdf, outgoingDirWs, λ, surface.position, surface.triangleFrame.n, surface.spawnOffset, interiorVolume, globalVolume, rand, envSamplesPerBounce, 1);
                    }

                    for (uint directCount = 0; directCount < meshSamplesPerBounce; directCount++) {
                        float2 rand = float2(rng.getFloat(), rng.getFloat());
                        path.radiance += path.throughput * estimateDirectVolumetric(scene.world, scene.tlas, scene.meshLights, bsdf, outgoingDirWs, λ, surface.position, surface.triangleFrame.n, surface.spawnOffset, interiorVolume, globalVolume, rand, meshSamplesPerBounce, 1);
                    }
                }

                // set up next bounce
                {
                    const BSDFSample sample = bsdf.sample(outgoingDirWs, float2(rng.getFloat(), rng.getFloat()));

                    const bool transmission = sign(dot(sample.dir, surface.triangleFrame.n)) != sign(dot(outgoingDirWs, surface.triangleFrame.n));
                    const bool entering = dot(sample.dir, surface.triangleFrame.n) < 0;
                    if (transmission) {
                        if (entering) {
                            path.volume = interiorVolume;
                        } else {
                            path.volume = globalVolume;
                        }
                    }

                    path.ray.direction = sample.dir;
                    path.ray.origin = surface.position + faceForward(surface.triangleFrame.n, path.ray.direction) * surface.spawnOffset;
                    path.pdf = material.isIndexMatched(λ, globalVolume.IOR) ? path.pdf : sample.eval.pdf; // preserve prior PDF for index-matched surfaces
                    path.throughput *= sample.eval.attenuation;
                }
            } else if (mediumTMax != 1.#INF) {
                path.throughput *= path.volume.medium.σ_s * path.volume.medium.transmittance(mediumTMax) / path.volume.medium.pdf(mediumTMax);

                const float3 outgoingDirWs = -path.ray.direction;
                const float3 position = path.ray.origin + path.ray.direction * mediumTMax;
                const Isotropic phaseFunction;

                for (uint directCount = 0; directCount < envSamplesPerBounce; directCount++) {
                    float2 rand = float2(rng.getFloat(), rng.getFloat());
                    path.radiance += path.throughput * estimateDirectVolumetric(scene.world, scene.tlas, scene.envMap, phaseFunction, outgoingDirWs, λ, position, 0, 0, path.volume, globalVolume, rand, envSamplesPerBounce, 1);
                }

                for (uint directCount = 0; directCount < meshSamplesPerBounce; directCount++) {
                    float2 rand = float2(rng.getFloat(), rng.getFloat());
                    path.radiance += path.throughput * estimateDirectVolumetric(scene.world, scene.tlas, scene.meshLights, phaseFunction, outgoingDirWs, λ, position, 0, 0, path.volume, globalVolume, rand, meshSamplesPerBounce, 1);
                }

                const BSDFSample sample = phaseFunction.sample(path.ray.direction, float2(rng.getFloat(), rng.getFloat()));
                path.ray.direction = sample.dir;
                path.ray.origin = position;
                path.pdf = sample.eval.pdf;
                path.throughput *= sample.eval.attenuation;
            } else {
                // traced an infinite ray that hit nothing
                break;
            }
            path.bounceCount += 1;

            // terminate if lost at russian roulette
            {
                const float pSurvive = (path.throughput == 0 || path.bounceCount > russianRouletteDepth ? min(0.95, path.throughput) : 1);
                if (rng.getFloat() < (1 - pSurvive)) return path.radiance;
                path.throughput /= pSurvive;
            }
        }

        // we only get here on misses -- terminations for other reasons return from loop

        // handle env map
        {
            const LightEvaluation l = scene.envMap.evaluate(λ, path.ray.direction);
            const float weight = misWeight(1, path.pdf, envSamplesPerBounce, l.pdf);
            path.radiance += path.throughput * l.radiance * weight;
        }

        return path.radiance;
    }
};

struct PathTracingIntegrator : Integrator {
    uint russianRouletteDepth;
    uint envSamplesPerBounce;
    uint meshSamplesPerBounce;

    static PathTracingIntegrator create(uint russianRouletteDepth, uint envSamplesPerBounce, uint meshSamplesPerBounce) {
        PathTracingIntegrator integrator;
        integrator.russianRouletteDepth = russianRouletteDepth;
        integrator.envSamplesPerBounce = envSamplesPerBounce;
        integrator.meshSamplesPerBounce = meshSamplesPerBounce;
        return integrator;
    }

    float incomingRadiance(const Scene scene, const Ray initialRay, const float λ, inout Rng rng) {
        Path path = Path::create(initialRay, scene.globalVolume.IOR.at(λ));

        for (Intersection its = Intersection::find(scene.tlas, path.ray); its.hit(); its = Intersection::find(scene.tlas, path.ray)) {
            const float3 outgoingDirWs = -path.ray.direction;

            // decode mesh attributes and material from intersection
            const SurfacePoint surface = scene.world.surfacePoint(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.barycentrics);
            const Material material = scene.world.material(its.instanceIndex, its.geometryIndex);
            const PolymorphicBSDF bsdf = PolymorphicBSDF::load(material, scene.globalVolume.IOR.at(λ), surface.texcoord, selectFrame(surface, material, outgoingDirWs), surface.triangleFrame, λ);

            // collect light from emissive meshes
            {
                const float lightPdf = areaMeasureToSolidAngleMeasure(surface.position, path.ray.origin, path.ray.direction, surface.triangleFrame.n) * scene.meshLights.areaPdf(its.instanceIndex, its.geometryIndex, its.primitiveIndex);
                const float weight = misWeight(1, path.pdf, meshSamplesPerBounce, lightPdf);
                path.radiance += path.throughput * material.getEmissive(λ, surface.texcoord) * weight;
            }

            // accumulate direct light samples
            if (!bsdf.isDelta()) {
                for (uint directCount = 0; directCount < envSamplesPerBounce; directCount++) {
                    float2 rand = float2(rng.getFloat(), rng.getFloat());
                    path.radiance += path.throughput * estimateDirect(scene.tlas, scene.envMap, bsdf, outgoingDirWs, λ, surface.position, surface.triangleFrame.n, surface.spawnOffset, rand, envSamplesPerBounce, 1);
                }

                for (uint directCount = 0; directCount < meshSamplesPerBounce; directCount++) {
                    float2 rand = float2(rng.getFloat(), rng.getFloat());
                    path.radiance += path.throughput * estimateDirect(scene.tlas, scene.meshLights, bsdf, outgoingDirWs, λ, surface.position, surface.triangleFrame.n, surface.spawnOffset, rand, meshSamplesPerBounce, 1);
                }
            }

            // set up next bounce
            {
                const BSDFSample sample = bsdf.sample(outgoingDirWs, float2(rng.getFloat(), rng.getFloat()));

                path.ray.direction = sample.dir;
                path.ray.origin = surface.position + faceForward(surface.triangleFrame.n, path.ray.direction) * surface.spawnOffset;
                path.pdf = sample.eval.pdf;
                path.throughput *= sample.eval.attenuation;
                path.bounceCount += 1;
            }

            // terminate if lost at russian roulette
            {
                const float pSurvive = (path.throughput == 0 || path.bounceCount > russianRouletteDepth ? min(0.95, path.throughput) : 1);
                if (rng.getFloat() < (1 - pSurvive)) return path.radiance;
                path.throughput /= pSurvive;
            }
        }

        // we only get here on misses -- terminations for other reasons return from loop

        // handle env map
        {
            const LightEvaluation l = scene.envMap.evaluate(λ, path.ray.direction);
            const float weight = misWeight(1, path.pdf, envSamplesPerBounce, l.pdf);
            path.radiance += path.throughput * l.radiance * weight;
        }

        return path.radiance;
    }
};

// primary ray + light sample
struct DirectLightIntegrator : Integrator {
    uint envSamples;
    uint meshSamples;
    uint brdfSamples;

    static DirectLightIntegrator create(uint envSamples, uint meshSamples, uint brdfSamples) {
        DirectLightIntegrator integrator;
        integrator.envSamples = envSamples;
        integrator.meshSamples = meshSamples;
        integrator.brdfSamples = brdfSamples;
        return integrator;
    }

    float incomingRadiance(const Scene scene, const Ray initialRay, const float λ, inout Rng rng) {
        float pathRadiance = 0;

        Intersection its = Intersection::find(scene.tlas, initialRay);
        if (its.hit()) {
            const float3 outgoingDirWs = -initialRay.direction;

            // decode mesh attributes and material from intersection
            const SurfacePoint surface = scene.world.surfacePoint(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.barycentrics);
            const Material material = scene.world.material(its.instanceIndex, its.geometryIndex);
            const PolymorphicBSDF bsdf = PolymorphicBSDF::load(material, scene.globalVolume.IOR.at(λ), surface.texcoord, selectFrame(surface, material, outgoingDirWs), surface.triangleFrame, λ);

            // collect light from emissive meshes
            pathRadiance += material.getEmissive(λ, surface.texcoord);

            if (!bsdf.isDelta()) {
                // accumulate direct light samples from env map
                for (uint directCount = 0; directCount < envSamples; directCount++) {
                    float2 rand = float2(rng.getFloat(), rng.getFloat());
                    pathRadiance += estimateDirect(scene.tlas, scene.envMap, bsdf, outgoingDirWs, λ, surface.position, surface.triangleFrame.n, surface.spawnOffset, rand, envSamples, brdfSamples);
                }

                // accumulate direct light samples from emissive meshes
                for (uint directCount = 0; directCount < meshSamples; directCount++) {
                    float2 rand = float2(rng.getFloat(), rng.getFloat());
                    pathRadiance += estimateDirect(scene.tlas, scene.meshLights, bsdf, outgoingDirWs, λ, surface.position, surface.triangleFrame.n, surface.spawnOffset, rand, meshSamples, brdfSamples);
                }
            }

            for (uint brdfSampleCount = 0; brdfSampleCount < brdfSamples; brdfSampleCount++) {
                const BSDFSample sample = bsdf.sample(outgoingDirWs, float2(rng.getFloat(), rng.getFloat()));
                if (sample.eval.attenuation != 0) {
                    Ray ray = initialRay;
                    ray.direction = sample.dir;
                    ray.origin = surface.position + faceForward(surface.triangleFrame.n, ray.direction) * surface.spawnOffset;
                    Intersection its = Intersection::find(scene.tlas, ray);
                    if (its.hit()) {
                        // hit -- collect light from emissive meshes
                        const SurfacePoint surface = scene.world.surfacePoint(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.barycentrics);
                        const float lightPdf = areaMeasureToSolidAngleMeasure(surface.position, ray.origin, ray.direction, surface.triangleFrame.n) * scene.meshLights.areaPdf(its.instanceIndex, its.geometryIndex, its.primitiveIndex);
                        const float weight = misWeight(brdfSamples, sample.eval.pdf, meshSamples, lightPdf);
                        pathRadiance += sample.eval.attenuation * scene.world.material(its.instanceIndex, its.geometryIndex).getEmissive(λ, surface.texcoord) * weight;
                    } else {
                        // miss -- collect light from env map
                        const LightEvaluation l = scene.envMap.evaluate(λ, ray.direction);
                        const float weight = misWeight(brdfSamples, sample.eval.pdf, envSamples, l.pdf);
                        pathRadiance += sample.eval.attenuation * l.radiance * weight;
                    }
                }
            }
        } else {
            // add background color
            pathRadiance += scene.envMap.evaluate(λ, initialRay.direction).radiance;
        }

        return pathRadiance;
    }
};
