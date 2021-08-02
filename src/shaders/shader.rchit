#version 460
#extension GL_EXT_ray_tracing : require

layout(location = 0) rayPayloadInEXT struct hitPayload {
    vec3 color;
} payload;

void main() {
    payload.color = vec3(0.0, 1.0, 0.0);
}
