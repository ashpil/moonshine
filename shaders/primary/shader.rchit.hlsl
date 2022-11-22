#include "payload.hlsl"

struct Mesh {
    uint64_t positionAddress;
    uint64_t texcoordAddress;
    uint64_t normalAddress; // may be zero, for no vertex normals

    uint64_t indexAddress;
};

struct Instance {
    uint materialIndex;
};

struct Vertex {
    float3 position;
    float2 texcoord;
};

SamplerState textureSampler : register(s1, space0);
Texture2D textures[] : register(t3, space0);
StructuredBuffer<Mesh> meshes : register(t4, space0);

StructuredBuffer<uint> meshIdxs : register(t5, space0);
StructuredBuffer<uint> materialIdxs : register(t6, space0);

float3 loadPosition(uint64_t addr, uint index) {
    return vk::RawBufferLoad<float3>(addr + sizeof(float3) * index);
}

float2 loadTexcoord(uint64_t addr, uint index) {
    return vk::RawBufferLoad<float2>(addr + sizeof(float2) * index);
}

float3 loadNormal(uint64_t addr, uint index) {
    return vk::RawBufferLoad<float3>(addr + sizeof(float3) * index);
}

float3x3 createTBNMatrix(float3 normal, float3 edge0, float3 edge1, float2 t0, float2 t1, float2 t2) {
    float2 deltaUV1 = t1 - t0;
    float2 deltaUV2 = t2 - t0;

    float f = deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y;

    float3 tangent = float3(
        (deltaUV2.y * edge0.x - deltaUV1.y * edge1.x) / f,
        (deltaUV2.y * edge0.y - deltaUV1.y * edge1.y) / f,
        (deltaUV2.y * edge0.z - deltaUV1.y * edge1.z) / f
    );
    
    float3 bitangent = float3(
        (-deltaUV2.x * edge0.x + deltaUV1.x * edge1.x) / f,
        (-deltaUV2.x * edge0.y + deltaUV1.x * edge1.y) / f,
        (-deltaUV2.x * edge0.z + deltaUV1.x * edge1.z) / f
    );

    float3x3 objectToTangent = { normalize(tangent), normalize(bitangent), normal };
    return transpose(objectToTangent);
}

float3 calculateNormal(uint64_t addr, uint3 ind, float3 barycentrics, float3 p0, float3 p1, float3 p2, float2 t0, float2 t1, float2 t2, float2 texcoords, uint textureIndex) {
    float3 edge0 = p1 - p0;
    float3 edge1 = p2 - p0;

    float3 normalObjectSpace;
    if (addr != 0) {
        float3 n0 = loadNormal(addr, ind.x);
        float3 n1 = loadNormal(addr, ind.y);
        float3 n2 = loadNormal(addr, ind.z);
        normalObjectSpace = barycentrics.x * n0 + barycentrics.y * n1 + barycentrics.z * n2;
    } else {
        normalObjectSpace = normalize(cross(edge0, edge1));
    }

    float3x3 tangentToObjectMat = createTBNMatrix(normalObjectSpace, edge0, edge1, t0, t1, t2);
    float2 textureNormal = (textures[NonUniformResourceIndex(5 * textureIndex + 4)].SampleLevel(textureSampler, texcoords, 0) * 2.0).rg - 1.0;
    float3 normalTangentSpace = float3(textureNormal, sqrt(1.0 - pow(textureNormal.r, 2) - pow(textureNormal.g, 2)));
    return normalize((mul(mul(WorldToObject4x3(), tangentToObjectMat), normalTangentSpace)).xyz);
}

float3 calculateHitPosition(float3 barycentrics, float3 v0, float3 v1, float3 v2) {
    float3 hitObjectSpace = barycentrics.x * v0 + barycentrics.y * v1 + barycentrics.z * v2;
    return mul(ObjectToWorld3x4(), float4(hitObjectSpace, 1.0));
}

float2 calculateTexcoord(float3 barycentrics, float2 t0, float2 t1, float2 t2) {
    return barycentrics.x * t0 + barycentrics.y * t1 + barycentrics.z * t2;
}

uint modelOffset() {
    return InstanceID() & 0xFFF; // lower 12 bits
}

uint skinOffset() {
    return InstanceID() >> 12; // upper 12 bits
}

uint meshIdx() {
    return meshIdxs[modelOffset() + GeometryIndex()];
}

uint materialIdx() {
    return materialIdxs[skinOffset() + GeometryIndex()];
}

[shader("closesthit")]
void main(inout Payload payload, in float2 attribs) {
    uint meshIndex = meshIdx();
    uint materialIndex = materialIdx();

    Mesh mesh = meshes[meshIndex];

    uint3 ind = vk::RawBufferLoad<uint3>(mesh.indexAddress + sizeof(uint3) * PrimitiveIndex());

    float3 p0 = loadPosition(mesh.positionAddress, ind.x);
    float3 p1 = loadPosition(mesh.positionAddress, ind.y);
    float3 p2 = loadPosition(mesh.positionAddress, ind.z);

    float2 t0 = loadTexcoord(mesh.texcoordAddress, ind.x);
    float2 t1 = loadTexcoord(mesh.texcoordAddress, ind.y);
    float2 t2 = loadTexcoord(mesh.texcoordAddress, ind.z);

    float3 barycentrics = float3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);

    payload.texcoord = calculateTexcoord(barycentrics, t0, t1, t2);
    payload.normal = calculateNormal(mesh.normalAddress, ind, barycentrics, p0, p1, p2, t0, t1, t2, payload.texcoord, materialIndex);
    payload.position = calculateHitPosition(barycentrics, p0, p1, p2);

    payload.done = false;
    payload.materialIndex = materialIndex;
    payload.index = InstanceIndex();
}
