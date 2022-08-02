struct MaterialData {
    float metallic;
    float ior;
};

SamplerState textureSampler : register(s1, space0);
StructuredBuffer<MaterialData> materialDatas : register(t2, space0);
Texture2D<float3> colorTextures[] : register(t3, space0);
Texture2D<float> roughnessTextures[] : register(t4, space0);

struct Material {
    float3 color;        // color; each component is (0, 1)
    float metallic;      // k_s - part it is specular. diffuse is (1 - specular); (0, 1) inclusive
    float roughness;     // roughness value; (0, 1) exclusive
    float ior;           // index of refraction; (0, ?) exclusive
};

Material getMaterial(uint materialIndex, float2 texcoords) {
    MaterialData materialData = materialDatas[NonUniformResourceIndex(materialIndex)];

    Material material;
    material.metallic = materialData.metallic;
    material.ior = materialData.ior;
    material.color = colorTextures[NonUniformResourceIndex(materialIndex)].SampleLevel(textureSampler, texcoords, 0);
    material.roughness = roughnessTextures[NonUniformResourceIndex(materialIndex)].SampleLevel(textureSampler, texcoords, 0);

    return material;
}

// schlick approximation
float3 F(float3 w_i, float3 m, Material material) {
    float R_0 = pow((1 - material.ior) / (1 + material.ior), 2);
    float3 mixed = lerp(float3(R_0, R_0, R_0), material.color, material.metallic);
    return mixed + (float3(1.0, 1.0, 1.0) - mixed) * pow((1 - dot(w_i, m)), 5);
}

// GGX
float D(float3 m, float roughness) {
    float cos_theta_m = frameCosTheta(m);
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
float G_1(float3 v, float3 m, float roughness) {
    float cos_theta_v = frameCosTheta(v);
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
float G(float3 w_i, float3 w_o, float3 m, float roughness) {
    return G_1(w_i, m, roughness) * G_1(w_o, m, roughness);
}

float3 cookTorrance(float3 w_i, float3 w_o, Material material) {
    float3 h = normalize(w_i + w_o);
    float3 fresnel = F(w_i, h, material);
    float geometry = G(w_i, w_o, h, material.roughness);
    float distribution = D(h, material.roughness);
    return (fresnel * geometry * distribution) / max(4 * abs(frameCosTheta(w_i)) * abs(frameCosTheta(w_o)), EPSILON);
}

float3 lambert(float3 w_i, float3 w_o, Material material) {
    return material.color / PI;
}

bool sameHemisphere(float3 v1, float3 v2) {
    return v1.z * v2.z > 0.0;
}

float lambertPDF(float3 w_i, float3 w_o, Material material) {
    return sameHemisphere(w_i, w_o) ? abs(frameCosTheta(w_i)) / PI : EPSILON;
}

float3 sampleLambert(float3 w_o, Material material, inout float pdf, float2 square) {
    float3 w_i = squareToCosineHemisphere(square);
    if (w_o.z < 0.0) {
        w_i.z *= -1;
    }

    pdf = lambertPDF(w_i, w_o, material);

    return w_i;
}

float3 sphericalTofloattor(float sinTheta, float cosTheta, float phi) {
    return float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
}

float3 sampleCookTorrance(float3 w_o, Material material, inout float pdf, float2 square) {
    // figure out spherical coords of half floattor
    float tanTheta = material.roughness * sqrt(square.x) / sqrt(1 - square.x);
    float cosThetaSquared = 1 / (1 + (tanTheta * tanTheta));
    float sinTheta = sqrt(max(0, 1 - cosThetaSquared));
    float cosTheta = sqrt(cosThetaSquared);
    float phi = 2 * PI * square.y;

    // convert them to cartesian
    float3 h = sphericalTofloattor(sinTheta, cosTheta, phi);
    if (!sameHemisphere(w_o, h)) {
        h = -h;
    }

    float3 w_i = -reflect(w_o, h);

    pdf = max(D(h, material.roughness) * abs(frameCosTheta(h)) / (4.0 * dot(w_o, h)), EPSILON);

    return w_i;
}

float cookTorrancePDF(float3 w_i, float3 w_o, Material material) {
    if (!sameHemisphere(w_o, w_i)) {
        return 0.0;
    }
    float3 h = normalize(w_i + w_o);
    float distributionPDF = D(h, material.roughness) * abs(frameCosTheta(h));
    return distributionPDF / (4.0 * dot(w_o, h));
}

float3 sample_f_r(float3 w_o, Material material, inout float pdf, float2 square) {
    if (square.x < material.metallic) {
        square.x /= material.metallic;
        float3 w_i = sampleCookTorrance(w_o, material, pdf, square);

        float pdf2 = lambertPDF(w_i, w_o, material);

        pdf = lerp(pdf2, pdf, material.metallic);
        return w_i;
    } else {
        square.x = (1 / (1.0 - material.metallic)) * (square.x - material.metallic);
        float3 w_i = sampleLambert(w_o, material, pdf, square);

        float pdf2 = cookTorrancePDF(w_i, w_o, material);

        pdf = lerp(pdf, pdf2, material.metallic);
        return w_i;
    }
}

float scatteringPDF(float3 w_i, float3 w_o, Material material) {
    float pdf1 = lambertPDF(w_i, w_o, material);
    float pdf2 = cookTorrancePDF(w_i, w_o, material);

    return lerp(pdf1, pdf2, material.metallic);
}

float3 f_r(float3 w_i, float3 w_o, Material material) {
    float3 microfacet = cookTorrance(w_i, w_o, material);
    float3 lambertian = lambert(w_i, w_o, material);
    return ((1.0 - material.metallic) * lambertian) + (material.metallic * microfacet);
}
