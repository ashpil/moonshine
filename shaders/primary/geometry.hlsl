struct Mesh {
    uint64_t positionAddress;
    uint64_t texcoordAddress; // may be zero, for no texcoords
    uint64_t normalAddress; // may be zero, for no vertex normals

    uint64_t indexAddress;
};

[[vk::binding(1, 0)]] StructuredBuffer<row_major float3x4> instanceToWorld;
[[vk::binding(2, 0)]] StructuredBuffer<row_major float3x4> worldToInstance;
[[vk::binding(3, 0)]] StructuredBuffer<Mesh> meshes;
[[vk::binding(4, 0)]] StructuredBuffer<uint> meshIdxs;
[[vk::binding(5, 0)]] StructuredBuffer<uint> materialIdxs;

float3 loadPosition(uint64_t addr, uint index) {
    return vk::RawBufferLoad<float3>(addr + sizeof(float3) * index);
}

float2 loadTexcoord(uint64_t addr, uint index) {
    return vk::RawBufferLoad<float2>(addr + sizeof(float2) * index);
}

float3 loadNormal(uint64_t addr, uint index) {
    return vk::RawBufferLoad<float3>(addr + sizeof(float3) * index);
}

void getTangentBitangent(float3 p0, float3 p1, float3 p2, float2 t0, float2 t1, float2 t2, out float3 tangent, out float3 bitangent) {
    float2 deltaUV1 = t1 - t0;
    float2 deltaUV2 = t2 - t0;

    float3 edge0 = p1 - p0;
    float3 edge1 = p2 - p0;

    float f = deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y;

    tangent = normalize(float3(
        (deltaUV2.y * edge0.x - deltaUV1.y * edge1.x) / f,
        (deltaUV2.y * edge0.y - deltaUV1.y * edge1.y) / f,
        (deltaUV2.y * edge0.z - deltaUV1.y * edge1.z) / f
    ));

    bitangent = normalize(float3(
        (-deltaUV2.x * edge0.x + deltaUV1.x * edge1.x) / f,
        (-deltaUV2.x * edge0.y + deltaUV1.x * edge1.y) / f,
        (-deltaUV2.x * edge0.z + deltaUV1.x * edge1.z) / f
    ));
}

template <typename T>
T interpolate(float3 barycentrics, T v1, T v2, T v3) {
    return barycentrics.x * v1 + barycentrics.y * v2 + barycentrics.z * v3;
}

uint modelOffset(uint instanceID) {
    return instanceID & 0xFFF; // lower 12 bits
}

uint skinOffset(uint instanceID) {
    return instanceID >> 12; // upper 12 bits
}

uint meshIdx(uint instanceID, uint geometryIndex) {
    return meshIdxs[NonUniformResourceIndex(modelOffset(instanceID) + geometryIndex)];
}

uint materialIdx(uint instanceID, uint geometryIndex) {
    return materialIdxs[NonUniformResourceIndex(skinOffset(instanceID) + geometryIndex)];
}

struct Attributes {
    float3 position;
    float2 texcoord;
    float3 normal;
    float3 tangent;
    float3 bitangent;

    static Attributes lookupAndInterpolate(Mesh mesh, float3 barycentrics, uint primitiveIndex) {
        Attributes attrs;

        uint3 ind = vk::RawBufferLoad<uint3>(mesh.indexAddress + sizeof(uint3) * primitiveIndex);

        // positions always available
        float3 p0 = loadPosition(mesh.positionAddress, ind.x);
        float3 p1 = loadPosition(mesh.positionAddress, ind.y);
        float3 p2 = loadPosition(mesh.positionAddress, ind.z);
        attrs.position = interpolate(barycentrics, p0, p1, p2);

        // texcoords optional
        float2 t0, t1, t2;
        if (mesh.texcoordAddress != 0) {
            t0 = loadTexcoord(mesh.texcoordAddress, ind.x);
            t1 = loadTexcoord(mesh.texcoordAddress, ind.y);
            t2 = loadTexcoord(mesh.texcoordAddress, ind.z);
        } else {
            // textures should be constant in this case
            t0 = float2(0, 0);
            t1 = float2(1, 0);
            t2 = float2(1, 1);
        }
        attrs.texcoord = interpolate(barycentrics, t0, t1, t2);

        // normals optional
        if (mesh.normalAddress != 0) {
            float3 n0 = loadNormal(mesh.normalAddress, ind.x);
            float3 n1 = loadNormal(mesh.normalAddress, ind.y);
            float3 n2 = loadNormal(mesh.normalAddress, ind.z);
            attrs.normal = interpolate(barycentrics, n0, n1, n2);
        } else {
            // just use one from positions
            attrs.normal = normalize(cross(p1 - p0, p2 - p0));
        }

        // at some point might have this in geometry too, but not yet
        getTangentBitangent(p0, p1, p2, t0, t1, t2, attrs.tangent, attrs.bitangent);

        return attrs;
    }
};

