#version 460
#extension GL_EXT_ray_tracing : require

layout(location = 0) rayPayloadInEXT struct hitPayload {
    vec3 attenuation;
    vec3 point;
    vec3 normal;
    bool done;
} payload;

void main() {
    vec3 dir = normalize(gl_WorldRayDirectionEXT);
    float t = 0.25 * (dir.y + 3.0);
    payload.attenuation = mix(vec3(1.0), vec3(0.5, 0.7, 1.0), t);
    payload.done = true;
}
