#version 460
#extension GL_EXT_ray_tracing : require

layout(location = 0) rayPayloadInEXT struct hitPayload {
    vec3 color;
} payload;

void main() {
    vec3 dir = normalize(gl_WorldRayDirectionEXT);
    float t = 0.25 * (dir.y + 3.0);
    payload.color = (1.0 - t) * vec3(1.0) + t * vec3(0.5, 0.7, 1.0);
}
