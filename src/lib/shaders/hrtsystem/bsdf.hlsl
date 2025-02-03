#pragma once

#include "../utils/mappings.hlsl"
#include "../utils/math.hlsl"
#include "spectrum.hlsl"

// most material code below expects stuff to be in the reflection frame

struct CauchyIOR {
    float a;
    float b;

    static CauchyIOR create(float a, float b) {
        CauchyIOR o;
        o.a = a;
        o.b = b;
        return o;
    }

    float at(const float λ) {
        return a + b / (λ * λ);
    }
};

interface MicrofacetDistribution {
    float D(float3 m);
    float G(float3 w_i, float3 w_o); // smith, backfacing facets should be ignored elsewhere
    float3 sample(float3 w_o, float2 square);
    float pdf(float3 w_o, float3 m);
};

// AKA Trowbridge-Reitz
struct GGX : MicrofacetDistribution {
    float α;

    static GGX create(float α) {
        GGX ggx;
        ggx.α = α;
        return ggx;
    }

    // GGX NDF
    // m must be in frame space
    float D(float3 m) {
        float α2 = pow(α, 2);
        float denom = PI * pow(pow(Frame::cosTheta(m), 2) * (α2 - 1) + 1, 2);
        return α2 / denom;
    }

    float Λ(float3 v) {
        float tan_theta_v_squared = Frame::tan2Theta(v);
        if (isinf(tan_theta_v_squared)) return 0.0f;
        return (sqrt(1.0f + pow(α, 2) * tan_theta_v_squared) - 1.0f) / 2.0f;
    }

    // w_i, w_o must be in frame space
    float G(float3 w_i, float3 w_o) {
        return 1.0f / (1.0f + Λ(w_i) + Λ(w_o));
    }

    // samples a half vector from the distribution
    // TODO: sample visible normals
    float3 sample(float3 w_o, float2 square) {
        // figure out spherical coords of half vector
        float tanThetaSquared = α * α * square.x / (1 - square.x);
        float cosThetaSquared = 1 / (1 + tanThetaSquared);
        float sinTheta = sqrt(max(0, 1 - cosThetaSquared));
        float cosTheta = sqrt(cosThetaSquared);
        float phi = 2 * PI * square.y;

        // convert them to cartesian
        float3 h = sphericalToCartesian(sinTheta, cosTheta, phi);
        if (!Frame::sameHemisphere(w_o, h)) h = -h;
        return h;
    }

    float pdf(float3 w_o, float3 m) {
        return D(m) * abs(Frame::cosTheta(m));
    }
};

// ηi is index of refraction for medium on current side of boundary
// ηt is index of refraction for medium on other side of boundary
// ηr is relative index of refraction (ηi / ηt)
namespace Fresnel {
    float schlickR0(float ηi, float ηt) {
        return pow((ηt - ηi) / (ηt + ηi), 2);
    }

    float schlickWeight(float cosTheta) {
        return pow(1 - cosTheta, 5);
    }

    float schlick(float cosTheta, float R0) {
        return lerp(schlickWeight(cosTheta), 1, R0);
    }

    // lerp between layer1 and layer2 based on schlick fresnel
    float fresnelLerp(float cosTheta, float ηi, float ηt, float layer1, float layer2) {
        const float f = schlick(cosTheta, schlickR0(ηi, ηt));
        return lerp(layer1, layer2, f);
    }

    // returns NaN for TIR
    float snellsLaw(const float cosThetaI, const float ηr) {
        const float sin2ThetaI = 1 - cosThetaI * cosThetaI;
        const float sin2ThetaT = (ηr * ηr) * sin2ThetaI;
        const float cosThetaT = sqrt(1 - sin2ThetaT);
        return cosThetaT;
    }

    // boundary of two dielectric surfaces
    float dielectric(const float cosTheta, const float ηr) {
        const float cosThetaI = clamp(abs(cosTheta), -1, 1);
        const float cosThetaT = snellsLaw(cosThetaI, ηr);

        if (isnan(cosThetaT)) return 1;

        const float r_parl = (cosThetaI - ηr * cosThetaT) / (cosThetaI + ηr * cosThetaT);
        const float r_perp = (ηr * cosThetaI - cosThetaT) / (ηr * cosThetaI + cosThetaT);

        return (r_parl * r_parl + r_perp * r_perp) / 2;
    }
};

struct BSDFEvaluation {
    float attenuation;
    float pdf;

    static BSDFEvaluation empty() {
        BSDFEvaluation eval;
        eval.attenuation = 0;
        eval.pdf = 0;
        return eval;
    }
};

struct BSDFSample {
    float3 dir;
    BSDFEvaluation eval;
};

interface BSDF {
    BSDFEvaluation evaluate(float3 w_o, float3 w_i);
    BSDFSample sample(float3 w_o, float2 square);
};

// evenly diffuse lambertian material
struct Lambert : BSDF {
    float reflectance; // fraction of light that is reflected

    static Lambert create(float reflectance) {
        Lambert lambert;
        lambert.reflectance = reflectance;
        return lambert;
    }

    static Lambert load(const uint64_t addr, const float2 texcoords, float λ) {
        uint colorTextureIndex = vk::RawBufferLoad<uint>(addr);

        Lambert material;
        material.reflectance = Spectrum::sampleReflectance(λ, dTextures[NonUniformResourceIndex(colorTextureIndex)].SampleLevel(dTextureSampler, texcoords, 0).rgb);
        return material;
    }

    BSDFEvaluation evaluate(float3 w_i, float3 w_o) {
        BSDFEvaluation eval;
        eval.attenuation = Frame::sameHemisphere(w_i, w_o) ? abs(Frame::cosTheta(w_i)) * reflectance / PI : 0.0;
        eval.pdf = Frame::sameHemisphere(w_i, w_o) ? abs(Frame::cosTheta(w_i)) / PI : 0.0;
        return eval;
    }

    BSDFSample sample(float3 w_o, float2 square) {
        float3 w_i = squareToCosineHemisphere(square);
        if (w_o.z < 0.0) w_i.z *= -1;

        BSDFSample sample;
        sample.dir = w_i;
        sample.eval = evaluate(w_i, w_o);
        // ideally we would never sample something with a zero pdf...
        // not sure if there's a bug here currently or if this is to be expected
        sample.eval.attenuation = sample.eval.pdf > 0 ? sample.eval.attenuation / sample.eval.pdf : 0;
        return sample;
    }

    static bool isDelta() {
        return false;
    }
};

// blends between provided microfacet distribution
// and lambertian diffuse based on metalness factor
struct StandardPBR : BSDF {
    GGX distr;      // microfacet distribution used by this material

    float reflectance; // reflectance - everywhere within [0, 1]
    float metalness; // metalness - k_s - part it is specular. diffuse is (1 - specular); [0, 1]
    float intIOR;
    float extIOR;

    static StandardPBR load(const uint64_t addr, const float extIOR, const float2 texcoords, const float λ) {
        uint colorTextureIndex = vk::RawBufferLoad<uint>(addr + sizeof(uint) * 0);
        uint metalnessTextureIndex = vk::RawBufferLoad<uint>(addr + sizeof(uint) * 1);
        uint roughnessTextureIndex = vk::RawBufferLoad<uint>(addr + sizeof(uint) * 2);
        float cauchyIORa = vk::RawBufferLoad<float>(addr + sizeof(uint) * 3);
        float cauchyIORb = vk::RawBufferLoad<float>(addr + sizeof(uint) * 4);

        StandardPBR material;
        material.reflectance = Spectrum::sampleReflectance(λ, dTextures[NonUniformResourceIndex(colorTextureIndex)].SampleLevel(dTextureSampler, texcoords, 0).rgb);
        material.metalness = dTextures[NonUniformResourceIndex(metalnessTextureIndex)].SampleLevel(dTextureSampler, texcoords, 0).r;
        float roughness = dTextures[NonUniformResourceIndex(roughnessTextureIndex)].SampleLevel(dTextureSampler, texcoords, 0).r;
        material.distr = GGX::create(max(pow(roughness, 2), 0.001));
        material.intIOR = CauchyIOR::create(cauchyIORa, cauchyIORb).at(λ);
        material.extIOR = extIOR;
        return material;
    }

    float microfacetPdf(float3 w_i, float3 w_o) {
        if (!Frame::sameHemisphere(w_o, w_i)) return 0.0;
        float3 h = normalize(w_i + w_o);
        return distr.pdf(w_o, h) / (4.0 * dot(w_o, h));
    }

    BSDFSample sample(float3 w_o, float2 square) {
        float specularWeight = 1;
        float diffuseWeight = 1 - metalness;
        float pSpecularSample = specularWeight / (specularWeight + diffuseWeight);

        BSDFSample sample;
        if (coinFlipRemap(pSpecularSample, square.x)) {
            float3 h = distr.sample(w_o, square);
            sample.dir = -reflect(w_o, h);
        } else {
            sample.dir = Lambert::create(reflectance).sample(w_o, square).dir;
        }
        sample.eval = evaluate(sample.dir, w_o);
        // ideally we would never sample something with a zero pdf...
        // not sure if there's a bug here currently or if this is to be expected
        sample.eval.attenuation = sample.eval.pdf > 0 ? sample.eval.attenuation / sample.eval.pdf : 0;
        return sample;
    }

    float pdf(float3 w_i, float3 w_o) {
        float specularWeight = 1;
        float diffuseWeight = 1 - metalness;
        float pSpecularSample = specularWeight / (specularWeight + diffuseWeight);

        float lambert_pdf = Lambert::create(reflectance).evaluate(w_i, w_o).pdf;
        float micro_pdf = microfacetPdf(w_i, w_o);

        return lerp(lambert_pdf, micro_pdf, pSpecularSample);
    }

    BSDFEvaluation evaluate(float3 w_i, float3 w_o) {
        float3 h = normalize(w_i + w_o);

        float fDielectric = Fresnel::dielectric(dot(w_i, h), extIOR / intIOR);
        float fMetallic = Fresnel::schlick(dot(w_i, h), reflectance);

        float F = lerp(fDielectric, fMetallic, metalness);
        float G = distr.G(w_i, w_o);
        float D = distr.D(h);
        float specular = Frame::sameHemisphere(w_o, w_i) ? (F * G * D) / (4 * abs(Frame::cosTheta(w_i)) * abs(Frame::cosTheta(w_o))) : 0;

        float diffuse = Lambert::create(reflectance).evaluate(w_i, w_o).attenuation;

        BSDFEvaluation eval;
        eval.attenuation = abs(Frame::cosTheta(w_i)) * specular + (1.0 - metalness) * diffuse;
        eval.pdf = pdf(w_i, w_o);
        return eval;
    }

    static bool isDelta() {
        return false;
    }
};

struct DisneyDiffuse : BSDF {
    float reflectance;
    float roughness;

    static DisneyDiffuse create(float reflectance, float roughness) {
        DisneyDiffuse material;
        material.reflectance = reflectance;
        material.roughness = roughness;
        return material;
    }

    BSDFSample sample(float3 w_o, float2 square) {
        return Lambert::create(reflectance).sample(w_o, square);
    }

    BSDFEvaluation evaluate(float3 w_i, float3 w_o) {
        BSDFEvaluation eval = Lambert::create(reflectance).evaluate(w_i, w_o);

        float3 h = normalize(w_i + w_o);
        float cosThetaHI = dot(w_i, h);

        float cosThetaNI = abs(Frame::cosTheta(w_i));
        float cosThetaNO = abs(Frame::cosTheta(w_o));
        float F_I = pow(1 - cosThetaNI, 5);
        float F_O = pow(1 - cosThetaNO, 5);

        float R_R = 2 * roughness * cosThetaHI * cosThetaHI;
        float retro = R_R * (F_I + F_O + F_I * F_O * (R_R - 1));

        eval.attenuation *= ((1 - F_I / 2) * (1 - F_O / 2) + retro);
        return eval;
    }

    static bool isDelta() {
        return false;
    }
};

struct PerfectMirror : BSDF {
    BSDFSample sample(float3 w_o, float2 square) {
        BSDFSample sample;
        sample.dir = float3(-w_o.x, -w_o.y, w_o.z);
        sample.eval.attenuation = 1;
        sample.eval.pdf = 1.#INF;
        return sample;
    }

    BSDFEvaluation evaluate(float3 w_i, float3 w_o) {
        return BSDFEvaluation::empty();
    }

    static bool isDelta() {
        return true;
    }
};

float3 refractDir(float3 wi, float3 n, float ηr) {
    const float cosThetaI = clamp(abs(dot(n, wi)), -1, 1);
    const float cosThetaT = Fresnel::snellsLaw(cosThetaI, ηr);

    if (isnan(cosThetaT)) return 1;

    return ηr * -wi + (ηr * cosThetaI - cosThetaT) * n;
}

struct Glass : BSDF {
    float intIOR;
    float extIOR;

    bool thin;

    static Glass load(const float intIOR, const float extIOR, const bool thin) {
        Glass material;
        material.intIOR = intIOR;
        material.extIOR = extIOR;
        material.thin = thin;
        return material;
    }

    BSDFSample sample(float3 w_o, float2 square) {
        const float etaR = (thin || Frame::cosTheta(w_o) > 0) ? extIOR / intIOR : intIOR / extIOR;

        const float fresnel = Fresnel::dielectric(Frame::cosTheta(w_o), etaR);

        float pReflect;
        if (thin && fresnel != 1) {
            pReflect = fresnel + (fresnel * fresnel) * (1 - fresnel) / (1 - fresnel * fresnel);
        } else {
            pReflect = fresnel;
        }

        BSDFSample sample;
        if (coinFlipRemap(pReflect, square.x)) {
            sample.dir = float3(-w_o.x, -w_o.y, w_o.z);
        } else {
            if (thin) {
                sample.dir = -w_o;
            } else {
                sample.dir = refractDir(w_o, faceForward(float3(0.0, 0.0, 1.0), w_o), etaR);
            }
        }
        if (all(sample.dir != 0.0)) {
            sample.eval.attenuation = 1;
            sample.eval.pdf = 1.#INF;
        } else {
            sample.eval = BSDFEvaluation::empty();
        }
        return sample;
    }

    BSDFEvaluation evaluate(float3 w_i, float3 w_o) {
        return BSDFEvaluation::empty();
    }

    static bool isDelta() {
        return true;
    }
};
