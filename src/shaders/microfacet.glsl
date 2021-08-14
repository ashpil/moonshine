const float PI = 3.14159265;


// helper
float X(float a) {
    if (a > 0.0) {
        return 1.0;
    } else {
        return 0.0;
    }
}

// schlick approximation
vec3 F(vec3 w_i, vec3 m, Material material) {
    float R_0 = pow((1 - material.ior) / (1 + material.ior), 2);
    vec3 mixed = mix(vec3(R_0), material.attenuation, material.metallic);
    return mixed + (vec3(1.0) - mixed) * pow((1 - dot(w_i, m)), 5);
}

// GGX
float D(vec3 m, vec3 n, float roughness) {
    float cos_theta_m = dot(m, n);
    if (cos_theta_m > 0.0) {
        float roughness_squared = pow(roughness, 2);
        float cos_theta_m_squared = pow(cos_theta_m, 2);
        float tan_theta_m_squared = (1.0 - cos_theta_m_squared) / cos_theta_m_squared;
        float denominator = PI * pow(cos_theta_m_squared, 2) * pow(roughness_squared + tan_theta_m_squared, 2);
        return roughness_squared / denominator;
    } else {
        return 0.0;
    }
}

// G_1 for GGX
float G_1(vec3 v, vec3 m, vec3 n, float roughness) {
    float cos_theta_v = dot(v, n);
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
float G(vec3 w_i, vec3 w_o, vec3 m, vec3 n, float roughness) {
    return G_1(w_i, m, n, roughness) * G_1(w_o, m, n, roughness);
}

vec3 cook_torrance(vec3 w_i, vec3 w_o, vec3 n, Material material) {
    vec3 h = normalize(w_i + w_o);
    vec3 fresnel = F(w_i, h, material);
    float geometry = G(w_i, w_o, h, n, material.roughness);
    float distribution = D(h, n, material.roughness);
    return (fresnel * geometry * distribution) / (4 * abs(dot(w_i, n)) * abs(dot(w_o, n)));
}

vec3 lambert(Material material) {
    return material.attenuation;
}

vec3 f_r(vec3 w_i, vec3 w_o, vec3 n, Material material) {
    vec3 microfacet = cook_torrance(w_i, w_o, n, material);
    return ((1.0 - material.metallic) * lambert(material)) + (material.metallic * microfacet);
}
