#include "../utils/math.hlsl"

// all code below expects stuff to be in the reflection frame

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

    float3 schlick(float cosTheta, float3 R0) {
        return lerp(schlickWeight(cosTheta), 1, R0);
    }

    // lerp between layer1 and layer2 based on schlick fresnel
    float3 fresnelLerp(float cosTheta, float ηi, float ηt, float3 layer1, float3 layer2) {
        float f = schlick(cosTheta, schlickR0(ηi, ηt));
        return lerp(layer1, layer2, f);
    }

    // boundary of two dielectric surfaces
    // PBRT version
    float dielectric(float cosThetaI, float ηi, float ηt) {
        cosThetaI = clamp(cosThetaI, -1, 1);

        // potentially swap indices of refraction
        // TODO: should this be here?
        bool entering = cosThetaI > 0;
        if (!entering) {
            float tmp = ηi;
            ηi = ηt;
            ηt = tmp;
            cosThetaI = abs(cosThetaI);
        }

        // compute cosThetaT using Snell's Law
        float sinThetaI = sqrt(max(0, 1 - cosThetaI * cosThetaI));
        float sinThetaT = ηi / ηt * sinThetaI;

        // handle total internal reflection
        if (sinThetaT >= 1) return 1;

        float cosThetaT = sqrt(max(0, 1 - sinThetaT * sinThetaT));

        float r_parl = ((ηt * cosThetaI) - (ηi * cosThetaT)) / ((ηt * cosThetaI) + (ηi * cosThetaT));
        float r_perp = ((ηi * cosThetaI) - (ηt * cosThetaT)) / ((ηi * cosThetaI) + (ηt * cosThetaT));

        return (r_parl * r_parl + r_perp * r_perp) / 2;
    }
};

struct MaterialSample {
    float3 dirFs;
    float pdf;
};

interface Material {
    float pdf(float3 w_o, float3 w_i);
    float3 eval(float3 w_o, float3 w_i);
    MaterialSample sample(float3 w_o, float2 square);
};

// evenly diffuse lambertian material
struct Lambert : Material {
    float3 r; // color (technically, fraction of light that is reflected)

    static Lambert create(float3 r) {
        Lambert lambert;
        lambert.r = r;
        return lambert;
    }

    static Lambert load(uint64_t addr, float2 texcoords) {
        uint colorTextureIndex = vk::RawBufferLoad<uint>(addr);

        Lambert material;
        material.r = dMaterialTextures[NonUniformResourceIndex(colorTextureIndex)].SampleLevel(dTextureSampler, texcoords, 0).rgb;
        return material;
    }

    float pdf(float3 w_i, float3 w_o) {
        return Frame::sameHemisphere(w_i, w_o) ? abs(Frame::cosTheta(w_i)) / PI : 0.0;
    }

    float3 eval(float3 w_i, float3 w_o) {
        return r / PI;
    }

    MaterialSample sample(float3 w_o, float2 square) {
        float3 w_i = squareToCosineHemisphere(square);
        if (w_o.z < 0.0) w_i.z *= -1;

        MaterialSample sample;
        sample.pdf = pdf(w_i, w_o);
        sample.dirFs = w_i;
        return sample;
    }

    static bool isDelta() {
        return false;
    }
};

// blends between provided microfacet distribution
// and lambertian diffuse based on metalness factor
struct StandardPBR : Material {
    GGX distr;      // microfacet distribution used by this material

    float3 color; // color - linear color; each component is [0, 1]
    float metalness; // metalness - k_s - part it is specular. diffuse is (1 - specular); [0, 1]
    float ior; // ior - internal index of refraction; [0, inf)

    static StandardPBR load(uint64_t addr, float2 texcoords) {
        uint colorTextureIndex = vk::RawBufferLoad<uint>(addr + sizeof(uint) * 0);
        uint metalnessTextureIndex = vk::RawBufferLoad<uint>(addr + sizeof(uint) * 1);
        uint roughnessTextureIndex = vk::RawBufferLoad<uint>(addr + sizeof(uint) * 2);
        float ior = vk::RawBufferLoad<float>(addr + sizeof(uint) * 3);

        StandardPBR material;
        material.color = dMaterialTextures[NonUniformResourceIndex(colorTextureIndex)].SampleLevel(dTextureSampler, texcoords, 0).rgb;
        material.metalness = dMaterialTextures[NonUniformResourceIndex(metalnessTextureIndex)].SampleLevel(dTextureSampler, texcoords, 0).r;
        float roughness = dMaterialTextures[NonUniformResourceIndex(roughnessTextureIndex)].SampleLevel(dTextureSampler, texcoords, 0).r;
        material.distr = GGX::create(max(pow(roughness, 2), 0.001));
        material.ior = ior;
        return material;
    }

    float microfacetPdf(float3 w_i, float3 w_o) {
        if (!Frame::sameHemisphere(w_o, w_i)) return 0.0;
        float3 h = normalize(w_i + w_o);
        return distr.pdf(w_o, h) / (4.0 * dot(w_o, h));
    }

    MaterialSample microfacetSample(float3 w_o, float2 square) {
        float3 h = distr.sample(w_o, square);
        float3 w_i = -reflect(w_o, h); // reflect in HLSL is negative of what papers usually mean for some reason

        MaterialSample sample;
        sample.pdf = Frame::sameHemisphere(w_o, w_i) ? distr.pdf(w_o, h) / (4.0 * dot(w_o, h)) : 0.0;
        sample.dirFs = w_i;
        return sample;
    }

    MaterialSample sample(float3 w_o, float2 square) {
        float specularWeight = 1;
        float diffuseWeight = 1 - metalness;
        float pSpecularSample = specularWeight / (specularWeight + diffuseWeight);

        MaterialSample sample;
        Lambert diffuse = Lambert::create(color);
        if (coinFlipRemap(pSpecularSample, square.x)) {
            MaterialSample microSample = microfacetSample(w_o, square);
            float pdf2 = diffuse.pdf(microSample.dirFs, w_o);

            sample.pdf = lerp(pdf2, microSample.pdf, pSpecularSample);
            sample.dirFs = microSample.dirFs;
        } else {
            MaterialSample diffuseSample = diffuse.sample(w_o, square);
            float pdf2 = microfacetPdf(diffuseSample.dirFs, w_o);

            sample.pdf = lerp(diffuseSample.pdf, pdf2, pSpecularSample);
            sample.dirFs = diffuseSample.dirFs;
        }
        return sample;
    }

    float pdf(float3 w_i, float3 w_o) {
        float specularWeight = 1;
        float diffuseWeight = 1 - metalness;
        float pSpecularSample = specularWeight / (specularWeight + diffuseWeight);

        float lambert_pdf = Lambert::create(color).pdf(w_i, w_o);
        float micro_pdf = microfacetPdf(w_i, w_o);

        return lerp(lambert_pdf, micro_pdf, pSpecularSample);
    }

    float3 eval(float3 w_i, float3 w_o) {
        float3 h = normalize(w_i + w_o);

        float3 fDielectric = Fresnel::dielectric(dot(w_i, h), AIR_IOR, ior);
        float3 fMetallic = Fresnel::schlick(dot(w_i, h), color);

        float3 F = lerp(fDielectric, fMetallic, metalness);
        float G = distr.G(w_i, w_o);
        float D = distr.D(h);
        float3 specular = Frame::sameHemisphere(w_o, w_i) ? (F * G * D) / (4.0 * abs(Frame::cosTheta(w_i)) * abs(Frame::cosTheta(w_o))) : 0.0;

        float3 diffuse = Lambert::create(color).eval(w_i, w_o);

        return specular + (1.0 - metalness) * diffuse;
    }

    static bool isDelta() {
        return false;
    }
};

struct DisneyDiffuse : Material {
    float3 color;
    float roughness;

    static DisneyDiffuse create(float3 color, float roughness) {
        DisneyDiffuse material;
        material.color = color;
        material.roughness = roughness;
        return material;
    }

    MaterialSample sample(float3 w_o, float2 square) {
        return Lambert::create(color).sample(w_o, square);
    }

    float pdf(float3 w_i, float3 w_o) {
        return Lambert::create(color).pdf(w_i, w_o);
    }

    float3 eval(float3 w_i, float3 w_o) {
        float3 lambertian = Lambert::create(color).eval(w_i, w_o);

        float3 h = normalize(w_i + w_o);
        float cosThetaHI = dot(w_i, h);

        float cosThetaNI = abs(Frame::cosTheta(w_i));
        float cosThetaNO = abs(Frame::cosTheta(w_o));
        float F_I = pow(1 - cosThetaNI, 5);
        float F_O = pow(1 - cosThetaNO, 5);

        float R_R = 2 * roughness * cosThetaHI * cosThetaHI;
        float3 retro = R_R * (F_I + F_O + F_I * F_O * (R_R - 1));

        return lambertian * ((1 - F_I / 2) * (1 - F_O / 2) + retro);
    }

    static bool isDelta() {
        return false;
    }
};

struct PerfectMirror : Material {
    MaterialSample sample(float3 w_o, float2 square) {
        MaterialSample sample;
        sample.pdf = 1.0;
        sample.dirFs = float3(-w_o.x, -w_o.y, w_o.z);
        return sample;
    }

    float pdf(float3 w_i, float3 w_o) {
        return 0.0;
    }

    float3 eval(float3 w_i, float3 w_o) {
        return 1.0 / abs(Frame::cosTheta(w_i));
    }

    static bool isDelta() {
        return true;
    }
};

float3 refractDir(float3 wi, float3 n, float eta) {
    float cosThetaI = dot(n, wi);
    float sin2ThetaI = max(0, 1 - cosThetaI * cosThetaI);
    float sin2ThetaT = eta * eta * sin2ThetaI;
    if (sin2ThetaT >= 1) return 0.0;

    float cosThetaT = sqrt(1 - sin2ThetaT);

    return eta * -wi + (eta * cosThetaI - cosThetaT) * n;
}

struct Glass : Material {
    float intIOR;

    static Glass load(uint64_t addr) {
        Glass material;
        material.intIOR = vk::RawBufferLoad<float>(addr);
        return material;
    }

    MaterialSample sample(float3 w_o, float2 square) {
        float fresnel = Fresnel::dielectric(Frame::cosTheta(w_o), AIR_IOR, intIOR);
        MaterialSample sample;

        if (square.x < fresnel) {
            sample.pdf = fresnel;
            sample.dirFs = float3(-w_o.x, -w_o.y, w_o.z);
        } else {
            float etaI;
            float etaT;
            if (Frame::cosTheta(w_o) > 0) {
                etaI = AIR_IOR;
                etaT = intIOR;
            } else {
                etaT = AIR_IOR;
                etaI = intIOR;
            }
            sample.dirFs = refractDir(w_o, faceForward(float3(0.0, 0.0, 1.0), w_o), etaI / etaT);
            sample.pdf = all(sample.dirFs == 0.0) ? 0.0 : 1.0 - fresnel;
        }
        return sample;
    }

    float pdf(float3 w_i, float3 w_o) {
        return 0.0;
    }

    float3 eval(float3 w_i, float3 w_o) {
        float fresnel = Fresnel::dielectric(Frame::cosTheta(w_o), AIR_IOR, intIOR);
        if (Frame::sameHemisphere(w_i, w_o)) {
            return fresnel / abs(Frame::cosTheta(w_i));
        } else {
            return (1.0 - fresnel) / abs(Frame::cosTheta(w_i));
        }
    }

    static bool isDelta() {
        return true;
    }
};

struct MaterialVariant : Material {
    MaterialType type;
    uint64_t addr;
    float2 texcoords;

    static MaterialVariant load(MaterialType type, uint64_t addr, float2 texcoords) {
        MaterialVariant material;
        material.type = type;
        material.addr = addr;
        material.texcoords = texcoords;
        return material;
    }

    float pdf(float3 w_i, float3 w_o) {
        switch (type) {
            case MaterialType::StandardPBR: {
                StandardPBR m = StandardPBR::load(addr, texcoords);
                return m.pdf(w_i, w_o);
            }
            case MaterialType::Lambert: {
                Lambert m = Lambert::load(addr, texcoords);
                return m.pdf(w_i, w_o);
            }
            case MaterialType::PerfectMirror: {
                PerfectMirror m;
                return m.pdf(w_i, w_o);
            }
            case MaterialType::Glass: {
                Glass m = Glass::load(addr);
                return m.pdf(w_i, w_o);
            }
        }
    }

    float3 eval(float3 w_i, float3 w_o) {
        switch (type) {
            case MaterialType::StandardPBR: {
                StandardPBR m = StandardPBR::load(addr, texcoords);
                return m.eval(w_i, w_o);
            }
            case MaterialType::Lambert: {
                Lambert m = Lambert::load(addr, texcoords);
                return m.eval(w_i, w_o);
            }
            case MaterialType::PerfectMirror: {
                PerfectMirror m;
                return m.eval(w_i, w_o);
            }
            case MaterialType::Glass: {
                Glass m = Glass::load(addr);
                return m.eval(w_i, w_o);
            }
        }
    }

    MaterialSample sample(float3 w_o, float2 square) {
        switch (type) {
            case MaterialType::StandardPBR: {
                StandardPBR m = StandardPBR::load(addr, texcoords);
                return m.sample(w_o, square);
            }
            case MaterialType::Lambert: {
                Lambert m = Lambert::load(addr, texcoords);
                return m.sample(w_o, square);
            }
            case MaterialType::PerfectMirror: {
                PerfectMirror m;
                return m.sample(w_o, square);
            }
            case MaterialType::Glass: {
                Glass m = Glass::load(addr);
                return m.sample(w_o, square);
            }
        }
    }

    bool isDelta() {
        switch (type) {
            case MaterialType::StandardPBR: {
                return StandardPBR::isDelta();
            }
            case MaterialType::Lambert: {
                return Lambert::isDelta();
            }
            case MaterialType::PerfectMirror: {
                return PerfectMirror::isDelta();
            }
            case MaterialType::Glass: {
                return Glass::isDelta();
            }
        }
    }
};

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

Frame getTextureFrame(uint materialIndex, float2 texcoords, Frame tangentFrame) {
    MaterialVariantData data = dMaterials[NonUniformResourceIndex(materialIndex)];
    float2 rg = dMaterialTextures[NonUniformResourceIndex(data.normal)].SampleLevel(dTextureSampler, texcoords, 0).rg;
    float3 normalTangentSpace = decodeNormal(rg);
    float3 normalWorldSpace = tangentNormalToWorld(normalTangentSpace, tangentFrame);
    return createTextureFrame(normalWorldSpace, tangentFrame);
}

float3 getEmissive(uint materialIndex, float2 texcoords) {
    MaterialVariantData data = dMaterials[NonUniformResourceIndex(materialIndex)];
    return dMaterialTextures[NonUniformResourceIndex(data.emissive)].SampleLevel(dTextureSampler, texcoords, 0).rgb;
}
