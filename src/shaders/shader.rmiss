#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_GOOGLE_include_directive : require

#include "common.glsl"

layout(location = 0) rayPayloadInEXT Payload payload;

void main() {
    vec3 dir = normalize(gl_WorldRayDirectionEXT);
    float t = 0.5 * (dir.y + 1.0);
    payload.attenuation = mix(vec3(0.5, 0.7, 1.0), vec3(0.5, 0.7, 1.0), t);
    payload.done = true;
}
