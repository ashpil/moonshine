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
    float2 deltaT02 = t0 - t2;
    float2 deltaT12 = t1 - t2;

    float3 deltaP02 = p0 - p2;
    float3 deltaP12 = p1 - p2;

    float det = deltaT02.x * deltaT12.y - deltaT02.y * deltaT12.x;
    if (det == 0.0) {
        coordinateSystem(normalize(cross(p2 - p0, p1 - p0)), tangent, bitangent);
    } else {
        tangent = normalize((deltaT12.y * deltaP02 - deltaT02.y * deltaP12) / det);
        bitangent = normalize((-deltaT12.x * deltaP02 + deltaT02.x * deltaP12) / det);
    }
}

template <typename T>
T interpolate(float3 barycentrics, T v1, T v2, T v3) {
    return barycentrics.x * v1 + barycentrics.y * v2 + barycentrics.z * v3;
}

Geometry getGeometry(uint instanceID, uint geometryIndex) {
    return dGeometries[NonUniformResourceIndex(instanceID + geometryIndex)];
}

uint meshIdx(uint instanceID, uint geometryIndex) {
    return getGeometry(instanceID, geometryIndex).meshIdx;
}

uint materialIdx(uint instanceID, uint geometryIndex) {
    return getGeometry(instanceID, geometryIndex).materialIdx;
}

struct MeshAttributes {
    float3 position;
    float2 texcoord;

    // from triangle positions
    float3 triangleNormal;
    float3 triangleTangent;
    float3 triangleBitangent;

    // from vertex attributes
    float3 normal;
    float3 tangent;
    float3 bitangent;

    static MeshAttributes lookupAndInterpolate(uint instanceIndex, uint geometryIndex, uint primitiveIndex, float2 attribs) {
        uint instanceID = dInstances[instanceIndex].instanceID();
        uint meshIndex = meshIdx(instanceID, geometryIndex);
        Mesh mesh = dMeshes[NonUniformResourceIndex(meshIndex)];
        float3 barycentrics = float3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);

        MeshAttributes attrs;

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

        getTangentBitangent(p0, p1, p2, t0, t1, t2, attrs.triangleTangent, attrs.triangleBitangent);
        attrs.triangleNormal = normalize(cross(p0 - p2, p1 - p2));

        // normals optional
        if (mesh.normalAddress != 0) {
            float3 n0 = loadNormal(mesh.normalAddress, ind.x);
            float3 n1 = loadNormal(mesh.normalAddress, ind.y);
            float3 n2 = loadNormal(mesh.normalAddress, ind.z);
            attrs.normal = normalize(interpolate(barycentrics, n0, n1, n2));

            attrs.bitangent = normalize(cross(attrs.normal, attrs.triangleTangent));
            attrs.tangent = cross(attrs.bitangent, attrs.normal);
            attrs.normal = normalize(cross(attrs.tangent, attrs.bitangent));
        } else {
            // just use ones from triangle
            attrs.normal = attrs.triangleNormal;
            attrs.tangent = attrs.triangleTangent;
            attrs.bitangent = attrs.triangleBitangent;
        }

        return attrs;
    }

     MeshAttributes inWorld(uint instanceIndex) {
        float3x4 toWorld = dInstances[NonUniformResourceIndex(instanceIndex)].transform;
        float3x4 toMesh = dWorldToInstance[NonUniformResourceIndex(instanceIndex)];

        position = mul(toWorld, float4(position, 1.0));

        triangleNormal = normalize(mul(transpose(toMesh), triangleNormal).xyz);
        triangleTangent = normalize(mul(transpose(toMesh), triangleTangent).xyz);
        triangleBitangent = normalize(mul(transpose(toMesh), triangleBitangent).xyz);

        normal = normalize(mul(transpose(toMesh), normal).xyz);
        tangent = normalize(mul(transpose(toMesh), tangent).xyz);
        bitangent = normalize(mul(transpose(toMesh), bitangent).xyz);

        return this;
     }
};

