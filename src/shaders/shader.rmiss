#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_GOOGLE_include_directive : require

#include "common.glsl"

layout(binding = 4) uniform samplerCube skySampler;

layout(location = 0) rayPayloadInEXT Payload payload;

void main() {
    vec3 dir = normalize(gl_WorldRayDirectionEXT);
    payload.attenuation = texture(skySampler, dir).xyz;
    payload.done = true;
}
