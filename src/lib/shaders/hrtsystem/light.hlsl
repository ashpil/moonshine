#pragma once

#include "world.hlsl"
#include "material.hlsl"
#include "spectrum.hlsl"
#include "../utils/reservoir.hlsl"

struct LightEvaluation {
    float radiance;
    float pdf;

    static LightEvaluation empty() {
        LightEvaluation eval;
        eval.radiance = 0;
        eval.pdf = 0;
        return eval;
    }
};

struct LightSample {
    float3 dirWs;
    float distance;
    LightEvaluation eval;
};

struct TriangleMetadata {
	uint instanceIndex;
	uint geometryIndex;
};

interface Light {
    // samples a light direction based on given position, returns
    // radiance at that point from light and pdf of this direction + radiance, ignoring visibility
    LightSample sample(float λ, float3 positionWs, float2 square);
};

struct EnvMap : Light {
    Texture2D<float3> rgbTexture;
    SamplerState sampler;
    Texture2D<float> luminanceTexture;

    static EnvMap create(Texture2D<float3> rgbTexture, SamplerState sampler, Texture2D<float> luminanceTexture) {
        EnvMap map;
        map.rgbTexture = rgbTexture;
        map.sampler = sampler;
        map.luminanceTexture = luminanceTexture;
        return map;
    }

    LightSample sample(float λ, float3 positionWs, float2 rand) {
        const uint size = textureDimensions(luminanceTexture).x;
        const uint mipCount = log2(size) + 1;

        uint2 idx = uint2(0, 0);
        for (uint level = mipCount; level-- > 0;) {
            Reservoir<uint2> r = Reservoir<uint2>::empty();
            for (uint i = 0; i < 2; i++) {
                for (uint j = 0; j < 2; j++) {
                    const uint2 coords = 2 * idx + uint2(i, j);
                    r.update(coords, luminanceTexture.Load(uint3(coords, level)), rand.x);
                }
            }
            idx = r.selected;
        }
        const float integral = luminanceTexture.Load(uint3(0, 0, mipCount - 1));

        const float discretePdf = luminanceTexture[idx] * float(size * size) / integral;
        const float2 uv = (float2(idx) + rand) / float2(size, size);

        LightSample lightSample;
        lightSample.dirWs = squareToEqualAreaSphere(uv);
        lightSample.distance = 1.#INF;
        lightSample.eval.pdf = discretePdf / (4.0 * PI);
        lightSample.eval.radiance = Spectrum::sampleEmission(λ, rgbTexture[idx]) / lightSample.eval.pdf;

        return lightSample;
    }

    // pdf is with respect to solid angle (no trace)
    LightEvaluation evaluate(float λ, float3 dirWs) {
        const uint size = textureDimensions(luminanceTexture).x;
        const uint mipCount = log2(size) + 1;
        const float integral = luminanceTexture.Load(uint3(0, 0, mipCount - 1));

        if (integral == 0) return LightEvaluation::empty();

        const float2 uv = squareToEqualAreaSphereInverse(dirWs);
        const uint2 idx = clamp(uint2(uv * size), uint2(0, 0), uint2(size, size));
        const float discretePdf = luminanceTexture[idx] * float(size * size) / integral;

        LightEvaluation eval;
        eval.pdf = discretePdf / (4.0 * PI);
        eval.radiance = Spectrum::sampleEmission(λ, rgbTexture[idx]);
        return eval;
    }
};

float areaMeasureToSolidAngleMeasure(float3 pos1, float3 pos2, float3 dir1, float3 dir2) {
    const float r2 = dot(pos1 - pos2, pos1 - pos2);
    const float lightCos = abs(dot(-dir1, dir2));

    return r2 / lightCos;
}

struct TriangleLight: Light {
    TriangleLocalSpace t;
    float3x4 toWorld;
    float3x4 toMesh;
    Material material;

    static TriangleLight create(uint instanceIndex, uint geometryIndex, uint primitiveIndex, World world) {
        TriangleLight light;
        light.t = world.triangleLocalSpace(instanceIndex, geometryIndex, primitiveIndex);
        light.toWorld = world.toWorld(instanceIndex);
        light.toMesh = world.toMesh(instanceIndex);
        light.material = world.material(instanceIndex, geometryIndex);
        return light;
    }

    LightSample sample(float λ, float3 positionWs, float2 rand) {
        const float2 barycentrics = squareToTriangle(rand);
        const SurfacePoint surface = t.surfacePoint(barycentrics, toWorld, toMesh);

        LightSample lightSample;
        lightSample.dirWs = normalize(surface.position - positionWs);
        lightSample.distance = distance(surface.position, positionWs) - surface.spawnOffset / abs(dot(lightSample.dirWs, surface.triangleFrame.n));
        lightSample.eval.pdf = areaMeasureToSolidAngleMeasure(surface.position, positionWs, lightSample.dirWs, surface.triangleFrame.n) / t.area(toWorld);
        lightSample.eval.radiance = material.getEmissive(λ, surface.texcoord) / lightSample.eval.pdf;

        return lightSample;
    }
};

// all mesh lights in scene
struct MeshLights : Light {
    Texture1D<float> power;
    StructuredBuffer<TriangleMetadata> metadata;
    StructuredBuffer<uint> geometryToTrianglePowerOffset;
    uint emissiveTriangleCount;
    World world;

    static MeshLights create(Texture1D<float> power, StructuredBuffer<TriangleMetadata> metadata, StructuredBuffer<uint> geometryToTrianglePowerOffset, uint emissiveTriangleCount, World world) {
        MeshLights lights;
        lights.power = power;
        lights.metadata = metadata;
        lights.geometryToTrianglePowerOffset = geometryToTrianglePowerOffset;
        lights.emissiveTriangleCount = emissiveTriangleCount;
        lights.world = world;
        return lights;
    }

    LightSample sample(float λ, float3 positionWs, float2 rand) {
        LightSample lightSample;
        lightSample.eval = LightEvaluation::empty();

        if (integral() == 0.0) return lightSample;

        const uint mipCount = uint(ceil(log2(emissiveTriangleCount))) + 1;

        uint idx = 0;
        for (uint level = mipCount; level-- > 0;) {
            Reservoir<uint> r = Reservoir<uint>::empty();
            for (uint i = 0; i < 2; i++) {
                const uint coord = 2 * idx + i;
                r.update(coord, power.Load(uint2(coord, level)), rand.x);
            }
            idx = r.selected;
        }
        const TriangleMetadata meta = metadata[idx];

        const uint instanceID = world.instances[meta.instanceIndex].instanceCustomIndex;
        const uint primitiveIndex = idx - geometryToTrianglePowerOffset[instanceID + meta.geometryIndex];

        const TriangleLight inner = TriangleLight::create(meta.instanceIndex, meta.geometryIndex, primitiveIndex, world);
        lightSample = inner.sample(λ, positionWs, rand);
        lightSample.eval.pdf *= selectionPdf(meta.instanceIndex, meta.geometryIndex, primitiveIndex);
        lightSample.eval.radiance /= selectionPdf(meta.instanceIndex, meta.geometryIndex, primitiveIndex);
        return lightSample;
    }

    float selectionPdf(uint instanceIndex, uint geometryIndex, uint primitiveIndex) {
        if (integral() == 0.0) return 0.0; // no lights
        const uint instanceID = world.instances[instanceIndex].instanceCustomIndex;
        const uint offset = geometryToTrianglePowerOffset[instanceID + geometryIndex];
        const uint invalidOffset = 0xFFFFFFFF;
        if (offset == invalidOffset) return 0.0; // no light at this triangle
        const uint idx = offset + primitiveIndex;
        return power.Load(uint2(idx, 0)) / integral();
    }

    float areaPdf(uint instanceIndex, uint geometryIndex, uint primitiveIndex) {
        const float triangleSelectionPdf = selectionPdf(instanceIndex, geometryIndex, primitiveIndex);
        const float triangleAreaPdf = 1.0 / world.triangleArea(instanceIndex, geometryIndex, primitiveIndex);
        return triangleSelectionPdf * triangleAreaPdf;
    }

    float integral() {
        const uint size = emissiveTriangleCount;

        if (size == 0) return 0;

        const uint mipCount = uint(ceil(log2(emissiveTriangleCount))) + 1;
        return power.Load(uint2(0, mipCount - 1));
    }
};
