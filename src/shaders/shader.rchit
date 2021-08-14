#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_GOOGLE_include_directive : require

#include "common.glsl"
#include "microfacet.glsl"

struct Instance {
    uint64_t vertexAddress;
    uint64_t indexAddress;
    Material material;
};

layout(buffer_reference, scalar) readonly buffer Indices { ivec3 i[]; };
layout(buffer_reference, scalar) readonly buffer Vertices { vec3 v[]; };

layout(binding = 3, set = 0, scalar) readonly buffer Instances { Instance instances[]; };

layout(location = 0) rayPayloadInEXT Payload payload;

hitAttributeEXT vec3 attribs;

vec3 calculateNormal(vec3 barycentrics, vec3 v0, vec3 v1, vec3 v2) {
    vec3 normalObjectSpace = normalize(cross(v1 - v0, v2 - v0));
    return normalize(gl_ObjectToWorldEXT * vec4(normalObjectSpace, 0.0));
}

vec3 calculateHitPoint(vec3 barycentrics, vec3 v0, vec3 v1, vec3 v2) {
    vec3 hitObjectSpace = barycentrics.x * v0 + barycentrics.y * v1 + barycentrics.z * v2;
    return gl_ObjectToWorldEXT * vec4(hitObjectSpace, 1.0);
}

void main() {
    Instance instance = instances[gl_InstanceID];
    Vertices vertices = Vertices(instance.vertexAddress);
    Indices indices = Indices(instance.indexAddress);
    ivec3 ind = indices.i[gl_PrimitiveID];
    vec3 v0 = vertices.v[ind.x];
    vec3 v1 = vertices.v[ind.y];
    vec3 v2 = vertices.v[ind.z];

    vec3 barycentrics = vec3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);
    vec3 normal = calculateNormal(barycentrics, v0, v1, v2);
    vec3 point = calculateHitPoint(barycentrics, v0, v1, v2);

    payload.point = point;
    payload.normal = normal;
    payload.done = false;
    payload.material = instance.material;
}
