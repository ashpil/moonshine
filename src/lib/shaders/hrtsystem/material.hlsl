#pragma once

[[vk::binding(0, 1)]] Texture2D dTextures[];
[[vk::binding(1, 1)]] SamplerState dTextureSampler;

#include "spectrum.hlsl"
#include "volume.hlsl"
#include "bsdf.hlsl"

float3 decodeNormal(float2 rg) {
    rg = rg * 2 - 1;
    return float3(rg, sqrt(1.0 - saturate(dot(rg, rg)))); // saturate due to float/compression annoyingness
}

float3 tangentNormalToWorld(float3 normalTangentSpace, Frame tangentFrame) {
    return normalize(tangentFrame.frameToWorld(normalTangentSpace)).xyz;
}

Frame createTextureFrame(float3 normalWorldSpace, Frame tangentFrame) {
    Frame textureFrame = tangentFrame;
    textureFrame.n = normalWorldSpace;
    textureFrame.reorthogonalize();

    return textureFrame;
}

enum class BSDFType : uint {
    Glass,
    Lambert,
    PerfectMirror,
    StandardPBR,
};

struct Material {
    uint normal;
    uint emissive;

    // volume enclosed by the mesh of this material
    ChromaticVolume volume;

    // find appropriate thing to decode from address using `type`
    BSDFType type;
    uint64_t addr;

    Frame getTextureFrame(float2 texcoords, Frame tangentFrame) {
        const float2 rg = dTextures[NonUniformResourceIndex(normal)].SampleLevel(dTextureSampler, texcoords, 0).rg;
        const float3 normalTangentSpace = decodeNormal(rg);
        const float3 normalWorldSpace = tangentNormalToWorld(normalTangentSpace, tangentFrame);
        return createTextureFrame(normalWorldSpace, tangentFrame);
    }

    float getEmissive(float λ, float2 texcoords) {
        return Spectrum::sampleEmission(λ, dTextures[NonUniformResourceIndex(emissive)].SampleLevel(dTextureSampler, texcoords, 0).rgb);
    }
};

struct PolymorphicBSDF : BSDF {
    BSDFType type;
    uint64_t addr;
    float2 texcoords;
    float λ;
    Frame shadingFrame;
    Frame triangleFrame;

    float intIOR;
    float extIOR;

    bool thin;

    static PolymorphicBSDF load(Material material, bool thin, float intIOR, float extIOR, float2 texcoords, Frame shadingFrame, Frame triangleFrame, float λ) {
        PolymorphicBSDF bsdf;
        bsdf.type = material.type;
        bsdf.addr = material.addr;
        bsdf.texcoords = texcoords;
        bsdf.λ = λ;
        bsdf.shadingFrame = shadingFrame;
        bsdf.triangleFrame = triangleFrame;
        bsdf.intIOR = thin ? material.volume.IOR.at(λ) : intIOR;
        bsdf.extIOR = extIOR;
        bsdf.thin = thin;
        return bsdf;
    }

    BSDFEvaluation evaluate(float3 w_i, float3 w_o) {
        BSDFEvaluation eval = BSDFEvaluation::empty();

        // zero out cases where the shading normal and geometric normal disagree on the type of event
        const bool geometricTransmission = sign(dot(w_i, triangleFrame.n)) != sign(dot(w_o, triangleFrame.n));
        const bool shadingTransmission = sign(dot(w_i, shadingFrame.n)) != sign(dot(w_o, shadingFrame.n));
        if (geometricTransmission != shadingTransmission) return eval;

        const float3 w_i_frame = shadingFrame.worldToFrame(w_i);
        const float3 w_o_frame = shadingFrame.worldToFrame(w_o);

        switch (type) {
            case BSDFType::StandardPBR: {
                StandardPBR m = StandardPBR::load(addr, extIOR, texcoords, λ);
                eval = m.evaluate(w_i_frame, w_o_frame);
                break;
            }
            case BSDFType::Lambert: {
                Lambert m = Lambert::load(addr, texcoords, λ);
                eval = m.evaluate(w_i_frame, w_o_frame);
                break;
            }
            case BSDFType::PerfectMirror: {
                PerfectMirror m;
                eval = m.evaluate(w_i_frame, w_o_frame);
                break;
            }
            case BSDFType::Glass: {
                Glass m = Glass::load(intIOR, extIOR, thin);
                eval = m.evaluate(w_i_frame, w_o_frame);
                break;
            }
        }

        return eval;
    }

    BSDFSample sample(float3 w_o, float2 square) {
        const float3 w_o_frame = shadingFrame.worldToFrame(w_o);
        BSDFSample sample;
        switch (type) {
            case BSDFType::StandardPBR: {
                StandardPBR m = StandardPBR::load(addr, extIOR, texcoords, λ);
                sample = m.sample(w_o_frame, square);
                break;
            }
            case BSDFType::Lambert: {
                Lambert m = Lambert::load(addr, texcoords, λ);
                sample = m.sample(w_o_frame, square);
                break;
            }
            case BSDFType::PerfectMirror: {
                PerfectMirror m;
                sample = m.sample(w_o_frame, square);
                break;
            }
            case BSDFType::Glass: {
                Glass m = Glass::load(intIOR, extIOR, thin);
                sample = m.sample(w_o_frame, square);
                break;
            }
        }
        sample.dir = shadingFrame.frameToWorld(sample.dir);

        // zero out cases where the shading normal and geometric normal disagree on the type of event
        const bool geometricTransmission = sign(dot(sample.dir, triangleFrame.n)) != sign(dot(w_o, triangleFrame.n));
        const bool shadingTransmission = sign(dot(sample.dir, shadingFrame.n)) != sign(dot(w_o, shadingFrame.n));
        if (geometricTransmission != shadingTransmission) {
            sample.eval.attenuation = 0;
            sample.eval.pdf = 0;
        }

        return sample;
    }

    bool isDelta() {
        switch (type) {
            case BSDFType::StandardPBR: {
                return StandardPBR::isDelta();
            }
            case BSDFType::Lambert: {
                return Lambert::isDelta();
            }
            case BSDFType::PerfectMirror: {
                return PerfectMirror::isDelta();
            }
            case BSDFType::Glass: {
                return Glass::isDelta();
            }
        }
    }
};
