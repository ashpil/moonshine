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

interface Light {
    // samples a light direction based on given position, returns
    // radiance at that point from light and pdf of this direction + radiance, ignoring visibility
    LightSample sample(float λ, float3 positionWs, float2 square);
};

struct EnvMap : Light {
    SamplerState sampler;
    Texture2D<float3> texture;

    static EnvMap create(Texture2D<float3> texture, SamplerState sampler) {
        EnvMap map;
        map.sampler = sampler;
        map.texture = texture;
        return map;
    }

    LightSample sample(float λ, float3 positionWs, float2 rand) {
        const uint size = textureDimensions(texture).x;
        const uint mipCount = log2(size) + 1;

        uint2 idx = uint2(0, 0);
        for (uint level = mipCount; level-- > 0;) {
            Reservoir<uint2> r = Reservoir<uint2>::empty();
            for (uint i = 0; i < 2; i++) {
                for (uint j = 0; j < 2; j++) {
                    const uint2 coords = 2 * idx + uint2(i, j);
                    r.update(coords, Spectrum::sampleEmission(λ, texture.Load(uint3(coords, level))), rand.x);
                }
            }
            idx = r.selected;
        }
        const float integral = Spectrum::sampleEmission(λ, texture.Load(uint3(0, 0, mipCount - 1)));

        const float discretePdf = Spectrum::sampleEmission(λ, texture[idx]) * float(size * size) / integral;
        const float2 uv = (float2(idx) + rand) / float2(size, size);

        LightSample lightSample;
        lightSample.dirWs = squareToEqualAreaSphere(uv);
        lightSample.distance = 1.#INF;
        lightSample.eval.pdf = discretePdf / (4.0 * PI);
        lightSample.eval.radiance = Spectrum::sampleEmission(λ, texture[idx]) / lightSample.eval.pdf;

        return lightSample;
    }

    // pdf is with respect to solid angle (no trace)
    LightEvaluation evaluate(float λ, float3 dirWs) {
        const uint size = textureDimensions(texture).x;
        const uint mipCount = log2(size) + 1;
        const float integral = Spectrum::sampleEmission(λ, texture.Load(uint3(0, 0, mipCount - 1)));

        if (integral == 0) return LightEvaluation::empty();

        const float2 uv = squareToEqualAreaSphereInverse(dirWs);
        const uint2 idx = clamp(uint2(uv * size), uint2(0, 0), uint2(size, size));
        const float discretePdf = Spectrum::sampleEmission(λ, texture[idx]) * float(size * size) / integral;

        LightEvaluation eval;
        eval.pdf = discretePdf / (4.0 * PI);
        eval.radiance = Spectrum::sampleEmission(λ, texture[idx]);
        return eval;
    }
};

float areaMeasureToSolidAngleMeasure(float3 pos1, float3 pos2, float3 dir1, float3 dir2) {
    const float r2 = dot(pos1 - pos2, pos1 - pos2);
    const float lightCos = abs(dot(-dir1, dir2));

    return r2 / lightCos;
}

struct TriangleLight: Light {
    TriangleLocalSpace tri;
    float3x4 toWorld;
    float3x4 toLocal;
    Material material;

    static TriangleLight create(TriangleLocalSpace tri, float3x4 toWorld, float3x4 toLocal, Material material) {
        TriangleLight light;
        light.tri = tri;
        light.toWorld = toWorld;
        light.toLocal = toLocal;
        light.material = material;
        return light;
    }

    LightSample sample(float λ, float3 positionWs, float2 rand) {
        const float2 barycentrics = squareToTriangle(rand);
        const SurfacePoint surface = tri.surfacePoint(barycentrics, toWorld, toLocal);

        LightSample lightSample;
        lightSample.dirWs = normalize(surface.position - positionWs);
        lightSample.distance = distance(surface.position, positionWs) - surface.spawnOffset / abs(dot(lightSample.dirWs, surface.triangleFrame.n));
        lightSample.eval.pdf = areaMeasureToSolidAngleMeasure(surface.position, positionWs, lightSample.dirWs, surface.triangleFrame.n) * areaPdf();
        lightSample.eval.radiance = material.getEmissive(λ, surface.texcoord) / lightSample.eval.pdf;

        return lightSample;
    }

    float areaPdf() {
        return 1.0 / tri.area(toLocal, toWorld);
    }
};

// all triangles in geometry
struct GeometryLight : Light {
    float3x4 toWorld;
    float3x4 toLocal;
    Geometry geometry;
    World world;

    static GeometryLight create(World world, Geometry geometry, float3x4 toWorld, float3x4 toLocal) {
        GeometryLight light;
        light.geometry = geometry;
        light.toWorld = toWorld;
        light.toLocal = toLocal;
        light.world = world;
        return light;
    }

    LightSample sample(float λ, float3 positionWs, float2 rand) {
        LightSample lightSample;
        lightSample.eval = LightEvaluation::empty();

        if (integral() == 0.0) return lightSample;

        const Mesh mesh = world.meshes[geometry.meshIndex];
        const Material material = world.materials[geometry.materialIndex];

        const uint levelCount = log2IntCeil(uint(mesh.triangleCount)) + 1;

        const float3x3 cofactor = abs(transpose((float3x3)toLocal) * determinant((float3x3)toWorld));

        uint idx = 0;
        for (uint level = 1; level < levelCount; level++) {
            Reservoir<uint> r = Reservoir<uint>::empty();
            for (uint i = 0; i < 2; i++) {
                const uint coord = 2 * idx + i;
                const float value = normL1(mul(cofactor, vk::RawBufferLoad<float3>(geometry.trianglePowersAddress + sizeof(float3) * ((1u << level) - 1 + coord))));
                r.update(coord, value, rand.x);
            }
            idx = r.selected;
        }
        const uint triangleIndex = idx;

        const TriangleLocalSpace tri = mesh.triangleLocalSpace(triangleIndex);
        const TriangleLight inner = TriangleLight::create(tri, toWorld, toLocal, material);

        lightSample = inner.sample(λ, positionWs, rand);
        lightSample.eval.pdf *= selectionPdf(triangleIndex);
        lightSample.eval.radiance /= selectionPdf(triangleIndex);
        return lightSample;
    }

    float selectionPdf(uint triangleIndex) {
        if (integral() == 0.0) return 0.0; // no lights
        const uint64_t triangleCount = world.meshes[geometry.meshIndex].triangleCount;
        const uint levelOffset = uint(geometry.trianglePowersSize - (triangleCount > 1 ? (triangleCount + (triangleCount % 2)) : 1));
        const float3x3 cofactor = abs(transpose((float3x3)toLocal) * determinant((float3x3)toWorld));
        return normL1(mul(cofactor, vk::RawBufferLoad<float3>(geometry.trianglePowersAddress + sizeof(float3) * (levelOffset + triangleIndex)))) / integral();
    }

    float integral() {
        if (world.meshes[geometry.meshIndex].triangleCount == 0) return 0;
        const float3x3 cofactor = abs(transpose((float3x3)toLocal) * determinant((float3x3)toWorld));
        return normL1(mul(cofactor, vk::RawBufferLoad<float3>(geometry.trianglePowersAddress)));
    }
};

// all geometries in model
struct ModelLight : Light {
    float3x4 toWorld;
    float3x4 toLocal;
    Model model;
    World world;

    static ModelLight create(World world, Model model, float3x4 toWorld, float3x4 toLocal) {
        ModelLight light;
        light.model = model;
        light.toWorld = toWorld;
        light.toLocal = toLocal;
        light.world = world;
        return light;
    }

    LightSample sample(float λ, float3 positionWs, float2 rand) {
        LightSample lightSample;
        lightSample.eval = LightEvaluation::empty();

        if (integral() == 0.0) return lightSample;

        const uint levelCount = log2IntCeil(uint(model.geometryCount)) + 1;

        const float3x3 cofactor = abs(transpose((float3x3)toLocal) * determinant((float3x3)toWorld));

        uint idx = 0;
        for (uint level = 1; level < levelCount; level++) {
            Reservoir<uint> r = Reservoir<uint>::empty();
            for (uint i = 0; i < 2; i++) {
                const uint coord = 2 * idx + i;
                const float value = normL1(mul(cofactor, vk::RawBufferLoad<float3>(model.geometryPowersAddress + sizeof(float3) * ((1u << level) - 1 + coord))));
                r.update(coord, value, rand.x);
            }
            idx = r.selected;
        }
        const uint geometryIndex = idx;

        const GeometryLight inner = GeometryLight::create(world, world.geometries[model.geometryOffset + geometryIndex], toWorld, toLocal);

        lightSample = inner.sample(λ, positionWs, rand);
        lightSample.eval.pdf *= selectionPdf(geometryIndex);
        lightSample.eval.radiance /= selectionPdf(geometryIndex);
        return lightSample;
    }

    float selectionPdf(uint geometryIndex) {
        if (integral() == 0.0) return 0.0; // no lights
        const uint levelOffset = uint(model.geometryPowersSize - (model.geometryCount > 1 ? (model.geometryCount + (model.geometryCount % 2)) : 1));
        const float3x3 cofactor = abs(transpose((float3x3)toLocal) * determinant((float3x3)toWorld));
        return normL1(mul(cofactor, vk::RawBufferLoad<float3>(model.geometryPowersAddress + sizeof(float3) * (levelOffset + geometryIndex)))) / integral();
    }

    float integral() {
        if (model.geometryCount == 0) return 0;
        const float3x3 cofactor = abs(transpose((float3x3)toLocal) * determinant((float3x3)toWorld));
        return normL1(mul(cofactor, vk::RawBufferLoad<float3>(model.geometryPowersAddress)));
    }
};

// all instance lights in scene
struct InstanceLights : Light {
    StructuredBuffer<float> power;
    uint count;
    World world;

    static InstanceLights create(StructuredBuffer<float> power, uint count, World world) {
        InstanceLights lights;
        lights.power = power;
        lights.count = count;
        lights.world = world;
        return lights;
    }

    LightSample sample(float λ, float3 positionWs, float2 rand) {
        LightSample lightSample;
        lightSample.eval = LightEvaluation::empty();

        if (integral() == 0.0) return lightSample;

        const uint levelCount = log2IntCeil(count) + 1;
        const uint bufferLevelCount = log2IntCeil((bufferDimensions(power) + 1) / 2) + 1;

        uint idx = 0;
        for (uint level = bufferLevelCount - levelCount + 1; level < bufferLevelCount; level++) {
            Reservoir<uint> r = Reservoir<uint>::empty();
            for (uint i = 0; i < 2; i++) {
                const uint coord = 2 * idx + i;
                r.update(coord, power[(1u << level) - 1 + coord], rand.x);
            }
            idx = r.selected;
        }
        const uint instanceIndex = idx;
        const Model model = world.models[world.instances[instanceIndex].instanceCustomIndex];
        const ModelLight inner = ModelLight::create(world, model, world.toWorld(instanceIndex), world.toLocal(instanceIndex));

        lightSample = inner.sample(λ, positionWs, rand);
        lightSample.eval.pdf *= selectionPdf(instanceIndex);
        lightSample.eval.radiance /= selectionPdf(instanceIndex);
        return lightSample;
    }

    float selectionPdf(uint instanceIndex) {
        if (integral() == 0.0) return 0.0; // no lights
        const uint levelOffset = ((bufferDimensions(power) + 1) / 2) - 1;
        return power[levelOffset + instanceIndex] / integral();
    }

    float areaPdf(uint instanceIndex, uint geometryIndex, uint primitiveIndex) {
        const Model model = world.models[world.instances[instanceIndex].instanceCustomIndex];
        const Geometry geometry = world.geometries[model.geometryOffset + geometryIndex];
        const Mesh mesh = world.meshes[geometry.meshIndex];
        const Material material = world.materials[geometry.materialIndex];

        const ModelLight modelLight = ModelLight::create(world, model, world.toWorld(instanceIndex), world.toLocal(instanceIndex));
        const GeometryLight geometryLight = GeometryLight::create(world, geometry, world.toWorld(instanceIndex), world.toLocal(instanceIndex));
        const TriangleLight triangleLight = TriangleLight::create(mesh.triangleLocalSpace(primitiveIndex), world.toWorld(instanceIndex), world.toLocal(instanceIndex), material);

        return selectionPdf(instanceIndex) * modelLight.selectionPdf(geometryIndex) * geometryLight.selectionPdf(primitiveIndex) * triangleLight.areaPdf();
    }

    float integral() {
        if (count == 0) return 0;
        return power[0];
    }
};
