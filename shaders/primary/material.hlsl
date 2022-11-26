#include "math.hlsl"

// `values` is what I call non-texture material properties
struct Values {
    float ior;
};

SamplerState textureSampler : register(s1, space0);
StructuredBuffer<Values> materialValues : register(t2, space0);
Texture2D materialTextures[] : register(t3, space0);

interface Material {
    float pdf(float3 w_i, float3 w_o);
    float3 sample(float3 w_o, inout float pdf, float2 square);
    float3 eval(float3 w_o, float3 w_i);
};

struct StandardPBR : Material {
    float3 color;        // linear color; each component is [0, 1]
    float3 emissive;     // linear emitted radiance; each component is [0, inf)
    float metalness;     // k_s - part it is specular. diffuse is (1 - specular); [0, 1]
    float roughness;     // roughness value; [0, 1)
    float ior;           // index of refraction; [0, inf)


    // schlick approximation
    static float3 F(float3 w_i, float3 m, StandardPBR material) {
        float R_0 = pow((1 - material.ior) / (1 + material.ior), 2);
        float3 mixed = lerp(float3(R_0, R_0, R_0), material.color, material.metalness);
        return mixed + (float3(1.0, 1.0, 1.0) - mixed) * pow((1 - dot(w_i, m)), 5);
    }

    // GGX NDF
    static float D(float3 m, float roughness) {
        float cos_theta_m = Frame::cosTheta(m);
        if (cos_theta_m > 0.0) {
            float roughness_squared = pow(roughness, 2);
            float cos_theta_m_squared = pow(cos_theta_m, 2);
            float tan_theta_m_squared = (1.0 - cos_theta_m_squared) / cos_theta_m_squared;
            float denominator = PI * pow(cos_theta_m_squared, 2) * max(pow(roughness_squared + tan_theta_m_squared, 2), EPSILON);
            return roughness_squared / denominator;
        } else {
            return 0.0;
        }
    }

    // G_1 for GGX
    static float G_1(float3 v, float3 m, float roughness) {
        float cos_theta_v = Frame::cosTheta(v);
        float val = dot(v, m) / cos_theta_v;
        if (val > 0.0) {
            float cos_theta_v_squared = pow(cos_theta_v, 2);
            float tan_theta_v_squared = (1.0 - cos_theta_v_squared) / cos_theta_v_squared;
            float root = sqrt(1.0 + pow(roughness, 2) * tan_theta_v_squared);
            return 2 / (1 + root);
        } else {
            return 0.0;
        }
    }

    // smith shadow-masking
    static float G(float3 w_i, float3 w_o, float3 m, float roughness) {
        return G_1(w_i, m, roughness) * G_1(w_o, m, roughness);
    }

    static float3 cookTorrance(float3 w_i, float3 w_o, StandardPBR material) {
        float3 h = normalize(w_i + w_o);
        float3 fresnel = F(w_i, h, material);
        float geometry = G(w_i, w_o, h, material.roughness);
        float distribution = D(h, material.roughness);
        return (fresnel * geometry * distribution) / max(4 * abs(Frame::cosTheta(w_i)) * abs(Frame::cosTheta(w_o)), EPSILON);
    }

    static float3 lambert(float3 w_i, float3 w_o, StandardPBR material) {
        return material.color / PI;
    }

    static float lambertPDF(float3 w_i, float3 w_o, StandardPBR material) {
        return Frame::sameHemisphere(w_i, w_o) ? abs(Frame::cosTheta(w_i)) / PI : EPSILON;
    }

    static float3 sampleLambert(float3 w_o, StandardPBR material, inout float pdf, float2 square) {
        float3 w_i = squareToCosineHemisphere(square);
        if (w_o.y < 0.0) {
            w_i.y *= -1;
        }

        pdf = lambertPDF(w_i, w_o, material);

        return w_i;
    }

    static float3 sampleCookTorrance(float3 w_o, StandardPBR material, inout float pdf, float2 square) {
        // figure out spherical coords of half vector
        float tanTheta = material.roughness * sqrt(square.x) / sqrt(1 - square.x);
        float cosThetaSquared = 1 / (1 + (tanTheta * tanTheta));
        float sinTheta = sqrt(max(0, 1 - cosThetaSquared));
        float cosTheta = sqrt(cosThetaSquared);
        float phi = 2 * PI * square.y;

        // convert them to cartesian
        float3 h = sphericalToCartesian(sinTheta, cosTheta, phi);
        float3 w_i = -reflect(w_o, h); // reflect in HLSL is negative of what papers usually mean for some reason

        pdf = max(D(h, material.roughness) * abs(Frame::cosTheta(h)) / (4.0 * dot(w_o, h)), EPSILON);

        return w_i;
    }

    static float cookTorrancePDF(float3 w_i, float3 w_o, StandardPBR material) {
        if (!Frame::sameHemisphere(w_o, w_i)) {
            return 0.0;
        }
        float3 h = normalize(w_i + w_o);
        float distributionPDF = D(h, material.roughness) * abs(Frame::cosTheta(h));
        return distributionPDF / (4.0 * dot(w_o, h));
    }

    float3 sample(float3 w_o, inout float pdf, float2 square) {
        if (square.x < this.metalness) {
            square.x /= this.metalness;
            float3 w_i = sampleCookTorrance(w_o, this, pdf, square);

            float pdf2 = lambertPDF(w_i, w_o, this);

            pdf = lerp(pdf2, pdf, this.metalness);
            return w_i;
        } else {
            square.x = (square.x - this.metalness) / (1.0 - this.metalness);
            float3 w_i = sampleLambert(w_o, this, pdf, square);

            float pdf2 = cookTorrancePDF(w_i, w_o, this);

            pdf = lerp(pdf, pdf2, this.metalness);
            return w_i;
        }
    }

    float pdf(float3 w_i, float3 w_o) {
        float pdf1 = lambertPDF(w_i, w_o, this);
        float pdf2 = cookTorrancePDF(w_i, w_o, this);

        return lerp(pdf1, pdf2, this.metalness);
    }

    float3 eval(float3 w_i, float3 w_o) {
        float3 microfacet = cookTorrance(w_i, w_o, this);
        float3 lambertian = lambert(w_i, w_o, this);

        return lerp(lambertian, microfacet, this.metalness);
    }
};

StandardPBR getMaterial(uint materialIndex, float2 texcoords) {
    Values values = materialValues[NonUniformResourceIndex(materialIndex)];

    StandardPBR material;
    material.ior = values.ior;
    material.color = materialTextures[NonUniformResourceIndex(5 * materialIndex + 0)].SampleLevel(textureSampler, texcoords, 0).rgb;
    material.metalness = materialTextures[NonUniformResourceIndex(5 * materialIndex + 1)].SampleLevel(textureSampler, texcoords, 0).r;
    material.roughness = materialTextures[NonUniformResourceIndex(5 * materialIndex + 2)].SampleLevel(textureSampler, texcoords, 0).r;
    material.emissive = materialTextures[NonUniformResourceIndex(5 * materialIndex + 3)].SampleLevel(textureSampler, texcoords, 0).rgb;
    material.roughness = max(material.roughness, 0.0001); // set minimum roughness otherwise current math breaks down

    return material;
}
