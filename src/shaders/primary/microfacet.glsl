
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_nonuniform_qualifier : require

struct MaterialData {
    float metallic;
    float ior;
};

layout(binding = 1, set = 0) uniform sampler textureSampler;
layout(binding = 2, set = 0, scalar) readonly buffer MaterialDatas { MaterialData materialDatas[]; };
layout(binding = 3, set = 0) uniform texture2D colorTextures[];
layout(binding = 4, set = 0) uniform texture2D roughnessTextures[];

struct Material {
    vec3 color;        // color; each component is (0, 1)
    float metallic;    // k_s - part it is specular. diffuse is (1 - specular); (0, 1) inclusive
    float roughness;   // roughness value; (0, 1) exclusive
    float ior;         // index of refraction; (0, ?) exclusive
};

Material getMaterial(uint materialIndex, vec2 texcoords) {

    MaterialData materialData = materialDatas[materialIndex];

    Material material;
    material.metallic = materialData.metallic;
    material.ior = materialData.ior;
    material.color = texture(sampler2D(colorTextures[nonuniformEXT(materialIndex)], textureSampler), texcoords).rgb;
    material.roughness = texture(sampler2D(roughnessTextures[nonuniformEXT(materialIndex)], textureSampler), texcoords).r;

    return material;
}

// schlick approximation
vec3 F(vec3 w_i, vec3 m, Material material) {
    float R_0 = pow((1 - material.ior) / (1 + material.ior), 2);
    vec3 mixed = mix(vec3(R_0), material.color, material.metallic);
    return mixed + (vec3(1.0) - mixed) * pow((1 - dot(w_i, m)), 5);
}

// GGX
float D(vec3 m, float roughness) {
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
float G_1(vec3 v, vec3 m, float roughness) {
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
float G(vec3 w_i, vec3 w_o, vec3 m, float roughness) {
    return G_1(w_i, m, roughness) * G_1(w_o, m, roughness);
}

vec3 cookTorrance(vec3 w_i, vec3 w_o, Material material) {
    vec3 h = normalize(w_i + w_o);
    vec3 fresnel = F(w_i, h, material);
    float geometry = G(w_i, w_o, h, material.roughness);
    float distribution = D(h, material.roughness);
    return (fresnel * geometry * distribution) / max(4 * abs(frameCosTheta(w_i)) * abs(frameCosTheta(w_o)), EPSILON);
}

vec3 lambert(vec3 w_i, vec3 w_o, Material material) {
    return material.color / PI;
}

bool sameHemisphere(vec3 v1, vec3 v2) {
    return v1.z * v2.z > 0.0;
}

float lambertPDF(vec3 w_i, vec3 w_o, Material material) {
    return sameHemisphere(w_i, w_o) ? abs(frameCosTheta(w_i)) / PI : EPSILON;
}

vec3 sampleLambert(vec3 w_o, Material material, inout float pdf, vec2 square) {
    vec3 w_i = squareToCosineHemisphere(square);
    if (w_o.z < 0.0) {
        w_i.z *= -1;
    }

    pdf = lambertPDF(w_i, w_o, material);

    return w_i;
}

vec3 sphericalToVector(float sinTheta, float cosTheta, float phi) {
    return vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
}

vec3 sampleCookTorrance(vec3 w_o, Material material, inout float pdf, vec2 square) {
    // figure out spherical coords of half vector
    float tanTheta = material.roughness * sqrt(square.x) / sqrt(1 - square.x);
    float cosThetaSquared = 1 / (1 + (tanTheta * tanTheta));
    float sinTheta = sqrt(max(0, 1 - cosThetaSquared));
    float cosTheta = sqrt(cosThetaSquared);
    float phi = 2 * PI * square.y;

    // convert them to cartesian
    vec3 h = sphericalToVector(sinTheta, cosTheta, phi);
    if (!sameHemisphere(w_o, h)) {
        h = -h;
    }

    vec3 w_i = -reflect(w_o, h);

    pdf = max(D(h, material.roughness) * abs(frameCosTheta(h)) / (4.0 * dot(w_o, h)), EPSILON);

    return w_i;
}

float cookTorrancePDF(vec3 w_i, vec3 w_o, Material material) {
    if (!sameHemisphere(w_o, w_i)) {
        return 0.0;
    }
    vec3 h = normalize(w_i + w_o);
    float distributionPDF = D(h, material.roughness) * abs(frameCosTheta(h));
    return distributionPDF / (4.0 * dot(w_o, h));
}

vec3 sample_f_r(vec3 w_o, Material material, inout float pdf, vec2 square) {
    if (square.x < material.metallic) {
        square.x /= material.metallic;
        vec3 w_i = sampleCookTorrance(w_o, material, pdf, square);

        float pdf2 = lambertPDF(w_i, w_o, material);

        pdf = mix(pdf2, pdf, material.metallic);
        return w_i;
    } else {
        square.x = (1 / (1.0 - material.metallic)) * (square.x - material.metallic);
        vec3 w_i = sampleLambert(w_o, material, pdf, square);

        float pdf2 = cookTorrancePDF(w_i, w_o, material);

        pdf = mix(pdf, pdf2, material.metallic);
        return w_i;
    }
}

vec3 f_r(vec3 w_i, vec3 w_o, Material material) {
    vec3 microfacet = cookTorrance(w_i, w_o, material);
    vec3 lambertian = lambert(w_i, w_o, material);
    return ((1.0 - material.metallic) * lambertian) + (material.metallic * microfacet);
}
