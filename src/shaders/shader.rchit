#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_GOOGLE_include_directive : require
#extension GL_EXT_nonuniform_qualifier : require

#include "common.glsl"

struct Instance {
    uint64_t vertexAddress;
    uint64_t indexAddress;
    float metallic;
    float ior;
};

struct Vertex {
    vec3 position;
    vec2 texcoord;
};

layout(buffer_reference, scalar) readonly buffer Indices { ivec3 i[]; };
layout(buffer_reference, scalar) readonly buffer Vertices { Vertex v[]; };

layout(binding = 2, set = 0) uniform sampler textureSampler;
layout(binding = 5, set = 0, scalar) readonly buffer Instances { Instance instances[]; };
layout(binding = 6, set = 0) uniform texture2D colorTextures[2]; // this needs to be kept in sync with texturearray's size in Engine.zig
layout(binding = 7, set = 0) uniform texture2D roughnessTextures[2]; // this needs to be kept in sync with texturearray's size in Engine.zig
layout(binding = 8, set = 0) uniform texture2D normalTextures[2]; // this needs to be kept in sync with texturearray's size in Engine.zig

layout(location = 0) rayPayloadInEXT Payload payload;

hitAttributeEXT vec3 attribs;

mat3 createTBNMatrix(vec3 normal, vec3 edge0, vec3 edge1, vec2 t0, vec2 t1, vec2 t2) {
    vec2 deltaUV1 = t1 - t0;
    vec2 deltaUV2 = t2 - t0;

    float f = deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y;

    vec3 tangent = vec3(
        (deltaUV2.y * edge0.x - deltaUV1.y * edge1.x) / f,
        (deltaUV2.y * edge0.y - deltaUV1.y * edge1.y) / f,
        (deltaUV2.y * edge0.z - deltaUV1.y * edge1.z) / f
    );
    
    vec3 bitangent = vec3(
        (-deltaUV2.x * edge0.x + deltaUV1.x * edge1.x) / f,
        (-deltaUV2.x * edge0.y + deltaUV1.x * edge1.y) / f,
        (-deltaUV2.x * edge0.z + deltaUV1.x * edge1.z) / f
    );

    return mat3(normalize(tangent), normalize(bitangent), normal);
}

vec3 calculateNormal(Vertex v0, Vertex v1, Vertex v2, vec2 texcoords) {
    vec3 edge0 = v1.position - v0.position;
    vec3 edge1 = v2.position - v0.position;
    vec3 positionNormalObjectSpace = normalize(cross(edge0, edge1));

    mat3 tangentToObjectMat = createTBNMatrix(positionNormalObjectSpace, edge0, edge1, v0.texcoord, v1.texcoord, v2.texcoord);
    vec2 textureNormal = (texture(sampler2D(normalTextures[nonuniformEXT(gl_InstanceID)], textureSampler), texcoords).rg * 2.0) - 1.0;
    vec3 normalTangentSpace = vec3(textureNormal, sqrt(1.0 - pow(textureNormal.r, 2) - pow(textureNormal.g, 2)));
    return normalize((gl_WorldToObject3x4EXT * tangentToObjectMat * normalTangentSpace).xyz);
}

vec3 calculateHitPoint(vec3 barycentrics, vec3 v0, vec3 v1, vec3 v2) {
    vec3 hitObjectSpace = barycentrics.x * v0 + barycentrics.y * v1 + barycentrics.z * v2;
    return gl_ObjectToWorldEXT * vec4(hitObjectSpace, 1.0);
}

vec2 calculateTexcoords(vec3 barycentrics, vec2 t0, vec2 t1, vec2 t2) {
    return barycentrics.x * t0 + barycentrics.y * t1 + barycentrics.z * t2;
}

void main() {
    Instance instance = instances[gl_InstanceID];
    Vertices vertices = Vertices(instance.vertexAddress);
    Indices indices = Indices(instance.indexAddress);
    ivec3 ind = indices.i[gl_PrimitiveID];
    Vertex v0 = vertices.v[ind.x];
    Vertex v1 = vertices.v[ind.y];
    Vertex v2 = vertices.v[ind.z];

    vec3 p0 = v0.position;
    vec3 p1 = v1.position;
    vec3 p2 = v2.position;

    vec2 t0 = v0.texcoord;
    vec2 t1 = v1.texcoord;
    vec2 t2 = v2.texcoord;

    vec3 barycentrics = vec3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);
    vec2 texcoords = calculateTexcoords(barycentrics, t0, t1, t2);
    vec3 normal = calculateNormal(v0, v1, v2, texcoords);
    vec3 point = calculateHitPoint(barycentrics, p0, p1, p2);

    payload.point = point;
    payload.normal = normal;
    payload.done = false;
    payload.material.metallic = instance.metallic;
    payload.material.ior = instance.ior;
    payload.material.color = texture(sampler2D(colorTextures[nonuniformEXT(gl_InstanceID)], textureSampler), texcoords).rgb;
    payload.material.roughness = texture(sampler2D(roughnessTextures[nonuniformEXT(gl_InstanceID)], textureSampler), texcoords).r;
}