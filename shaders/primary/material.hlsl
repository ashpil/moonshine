#include "math.hlsl"

// all code below expects stuff to be in the reflection frame

interface MicrofacetDistribution {
    float D(float3 m);
    float G(float3 w_i, float3 w_o, float3 m);
    float3 sample(float3 w_o, float2 square);
    float pdf(float3 w_o, float3 h);
};

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
        float cos_theta_m = Frame::cosTheta(m);
        if (cos_theta_m > 0.0) {
            float α2 = pow(α, 2);
            float cos_theta_m_squared = pow(cos_theta_m, 2);
            float tan_theta_m_squared = (1.0 - cos_theta_m_squared) / cos_theta_m_squared;
            float denominator = PI * pow(cos_theta_m_squared, 2) * pow(α2 + tan_theta_m_squared, 2);
            return α2 / denominator;
        } else {
            return 0.0;
        }
    }

    // G_1 for GGX
    // v, m must be in frame space
    float G_1(float3 v, float3 m) {
        float cos_theta_v = Frame::cosTheta(v);
        float val = dot(v, m) / cos_theta_v;
        if (val > 0.0) {
            float cos_theta_v_squared = pow(cos_theta_v, 2);
            float tan_theta_v_squared = (1.0 - cos_theta_v_squared) / cos_theta_v_squared;
            float root = sqrt(1.0 + pow(α, 2) * tan_theta_v_squared);
            return 2 / (1 + root);
        } else {
            return 0.0;
        }
    }

    // smith shadow-masking for GGX
    // w_i, w_o, m must be in frame space
    float G(float3 w_i, float3 w_o, float3 m) {
        return G_1(w_i, m) * G_1(w_o, m);
    }

    // samples a half vector from the distribution
    float3 sample(float3 w_o, float2 square) {
        // figure out spherical coords of half vector
        float tanTheta = α * sqrt(square.x) / sqrt(1 - square.x);
        float cosThetaSquared = 1 / (1 + (tanTheta * tanTheta));
        float sinTheta = sqrt(max(0, 1 - cosThetaSquared));
        float cosTheta = sqrt(cosThetaSquared);
        float phi = 2 * PI * square.y;

        // convert them to cartesian
        float3 h = sphericalToCartesian(sinTheta, cosTheta, phi);
        if (!Frame::sameHemisphere(w_o, h)) h = -h;
        return h;
    }

    float pdf(float3 w_o, float3 h) {
        return D(h) * abs(Frame::cosTheta(h));
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

    // schlick approximation + tinting
    float3 tintedSchlick(float cosTheta, float ηi, float ηt, float3 tint, float factor) {
        float R0 = schlickR0(ηi, ηt);
        float3 mixed = lerp(R0, tint, factor);
        return schlick(cosTheta, mixed);
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

    float pdf(float3 w_i, float3 w_o) {
        return Frame::sameHemisphere(w_i, w_o) ? abs(Frame::cosTheta(w_i)) / PI : 0.0;
    }

    float3 eval(float3 w_i, float3 w_o) {
        return r / PI;
    }

    MaterialSample sample(float3 w_o, float2 square) {
        float3 w_i = squareToCosineHemisphere(square);
        if (w_o.y < 0.0) w_i.y *= -1;

        MaterialSample sample;
        sample.pdf = pdf(w_i, w_o);
        sample.dirFs = w_i;
        return sample;
    }
};

// blends between provided microfacet distribution
// and lambertian diffuse based on metalness factor
struct StandardPBR : Material {
    GGX distr;      // microfacet distribution used by this material

    float3 color; // color - linear color; each component is [0, 1]
    float metalness; // metalness - k_s - part it is specular. diffuse is (1 - specular); [0, 1]
    float roughness; // roughness - roughness value; [0, 1)
    float ior; // ior - internal index of refraction; [0, inf)

    static StandardPBR create(float3 color, float metalness, float roughness, float ior) {
        roughness = max(roughness, 0.004); // set minimum roughness otherwise current math breaks down a bit
        
        StandardPBR material;
        material.color = color;
        material.metalness = metalness;
        material.ior = ior;
        material.distr = GGX::create(roughness);
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

    float3 microfacetEval(float3 w_i, float3 w_o) {
        float3 h = normalize(w_i + w_o);
        float3 F = Fresnel::tintedSchlick(dot(w_i, h), 1, ior, color, metalness);
        float G = distr.G(w_i, w_o, h);
        float D = distr.D(h);
        return (F * G * D) / (4 * abs(Frame::cosTheta(w_i)) * abs(Frame::cosTheta(w_o)));
    }

    MaterialSample sample(float3 w_o, float2 square) {
        MaterialSample sample;
        Lambert lambert = Lambert::create(color);
        if (coinFlipRemap(this.metalness, square.x)) {
            MaterialSample microSample = microfacetSample(w_o, square);
            float pdf2 = lambert.pdf(microSample.dirFs, w_o);

            sample.pdf = lerp(pdf2, microSample.pdf, this.metalness);
            sample.dirFs = microSample.dirFs;
        } else {
            MaterialSample lambertSample = lambert.sample(w_o, square);
            float pdf2 = microfacetPdf(lambertSample.dirFs, w_o);

            sample.pdf = lerp(lambertSample.pdf, pdf2, this.metalness);
            sample.dirFs = lambertSample.dirFs;
        }
        return sample;
    }

    float pdf(float3 w_i, float3 w_o) {
        float lambert_pdf = Lambert::create(color).pdf(w_i, w_o);
        float micro_pdf = microfacetPdf(w_i, w_o);

        return lerp(lambert_pdf, micro_pdf, this.metalness);
    }

    float3 eval(float3 w_i, float3 w_o) {
        float3 microfacet = microfacetEval(w_i, w_o);
        float3 lambertian = Lambert::create(color).eval(w_i, w_o);

        return lerp(lambertian, microfacet, this.metalness);
    }
};

// TODO: transmission
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
};

float3 decodeNormal(float2 rg) {
    rg = rg * 2 - 1;
    return float3(rg, sqrt(1.0 - saturate(dot(rg, rg)))); // saturate due to float/compression annoyingness
}

Frame lookupTextureNormal(uint textureIndex, float2 texcoords, Frame tangentFrame) {
    float3 tmp = tangentFrame.n;
    tangentFrame.n = tangentFrame.t;
    tangentFrame.t = tmp;

    float3 normalTangentSpace = decodeNormal(dMaterialTextures[NonUniformResourceIndex(textureIndex)].SampleLevel(dTextureSampler, texcoords, 0).rg);

    Frame textureFrame = tangentFrame;
    textureFrame.n = normalize(tangentFrame.frameToWorld(normalTangentSpace).xyz);
    textureFrame.reorthogonalize();

    return textureFrame;
}

// sort of a weird system rn
// represents all parameters a material might have
// then, to get a specific interpretation of these parameters,
// just call getX where X is the specific material model
//
// the purpose of this is to be able to easily swap material models when testing
// as well as somewhere to store material parameters that aren't really reliant on a specific material model,
// such as the normal or emissive map
struct MaterialParameters {
    float ior;
    float3 color;
    float metalness;
    float roughness;

    float3 emissive;

    Frame frame;

    static MaterialParameters create(uint materialIndex, float2 texcoords, Frame tangentFrame) {
        MaterialInput input = dMaterials[NonUniformResourceIndex(materialIndex)];

        MaterialParameters params;
        params.ior = input.ior;
        params.color = dMaterialTextures[NonUniformResourceIndex(input.color)].SampleLevel(dTextureSampler, texcoords, 0).rgb;
        params.emissive = dMaterialTextures[NonUniformResourceIndex(input.emissive)].SampleLevel(dTextureSampler, texcoords, 0).rgb;
        params.metalness = dMaterialTextures[NonUniformResourceIndex(input.metalness)].SampleLevel(dTextureSampler, texcoords, 0).r;
        params.roughness = dMaterialTextures[NonUniformResourceIndex(input.roughness)].SampleLevel(dTextureSampler, texcoords, 0).r;
        params.frame = lookupTextureNormal(input.normal, texcoords, tangentFrame);
        return params;
    }

    StandardPBR getStandardPBR() {
        return StandardPBR::create(color, metalness, roughness, ior);
    }

    Lambert getLambert() {
        return Lambert::create(color);
    }

    DisneyDiffuse getDisneyDiffuse() {
        return DisneyDiffuse::create(color, roughness);
    }
};
