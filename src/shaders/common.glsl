const float PI = 3.14159265;
const float EPSILON = 0.000000119;

struct Material {
    vec3 attenuation;  // color; each component is (0, 1)
    float metallic;    // k_s - part it is specular. diffuse is (1 - specular); (0, 1) inclusive
    float roughness;       // roughness value; (0, 1) exclusive
    float ior;         // index of refraction; (0, ?) exclusive
};

struct Payload {
    vec3 point;
    vec3 normal;
    bool done;
    Material material;
};
