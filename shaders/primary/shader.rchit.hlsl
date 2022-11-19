#include "payload.hlsl"

struct Mesh {
    uint64_t vertexAddress;
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

StructuredBuffer<uint> modelIdxToOffset : register(t5, space0);
StructuredBuffer<uint> offsetGeoIdxToMeshIdx : register(t6, space0);

StructuredBuffer<uint> skinIdxToOffset : register(t7, space0);
StructuredBuffer<uint> offsetGeoIdxToMaterialIdx : register(t8, space0);

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

float3 calculateNormal(Vertex v0, Vertex v1, Vertex v2, float2 texcoords, uint textureIndex) {
    float3 edge0 = v1.position - v0.position;
    float3 edge1 = v2.position - v0.position;
    float3 positionNormalObjectSpace = normalize(cross(edge0, edge1));

    float3x3 tangentToObjectMat = createTBNMatrix(positionNormalObjectSpace, edge0, edge1, v0.texcoord, v1.texcoord, v2.texcoord);
    float2 textureNormal = (textures[NonUniformResourceIndex(4 * textureIndex + 3)].SampleLevel(textureSampler, texcoords, 0) * 2.0).rg - 1.0;
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

Vertex loadVertex(uint64_t addr, uint index) {
    // FIXME: why doesn't loading a whole Vertex at once work?
    Vertex v;
    v.position = vk::RawBufferLoad<float3>(addr + sizeof(Vertex) * index);
    v.texcoord = vk::RawBufferLoad<float2>(addr + sizeof(Vertex) * index + sizeof(float3));
    return v;
}

uint modelIdx() {
    return InstanceID() & 0xFFF; // lower 12 bits
}

uint skinIdx() {
    return InstanceID() >> 12; // upper 12 bits
}

uint meshIdx(uint modelIdx, uint geometryIdx) {
    uint offset = modelIdxToOffset[modelIdx];
    return offsetGeoIdxToMeshIdx[offset + geometryIdx];
}

uint materialIdx(uint skinIdx, uint geometryIdx) {
    uint offset = skinIdxToOffset[skinIdx];
    return offsetGeoIdxToMaterialIdx[offset + geometryIdx];
}

[shader("closesthit")]
void main(inout Payload payload, in float2 attribs) {
    uint meshIndex = meshIdx(modelIdx(), GeometryIndex());
    uint materialIndex = materialIdx(skinIdx(), GeometryIndex());

    Mesh mesh = meshes[meshIndex];

    uint3 ind = vk::RawBufferLoad<uint3>(mesh.indexAddress + sizeof(uint3) * PrimitiveIndex());
    
    Vertex v0 = loadVertex(mesh.vertexAddress, ind.x);
    Vertex v1 = loadVertex(mesh.vertexAddress, ind.y);
    Vertex v2 = loadVertex(mesh.vertexAddress, ind.z);

    float3 p0 = v0.position;
    float3 p1 = v1.position;
    float3 p2 = v2.position;

    float2 t0 = v0.texcoord;
    float2 t1 = v1.texcoord;
    float2 t2 = v2.texcoord;

    float3 barycentrics = float3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);

    payload.texcoord = calculateTexcoord(barycentrics, t0, t1, t2);
    payload.normal = calculateNormal(v0, v1, v2, payload.texcoord, materialIndex);
    payload.position = calculateHitPosition(barycentrics, p0, p1, p2);

    payload.done = false;
    payload.materialIndex = materialIndex;
    payload.index = InstanceIndex();
}
