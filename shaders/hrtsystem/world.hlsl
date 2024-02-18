#pragma once

#include "reflection_frame.hlsl"


struct Instance { // same required by vulkan on host side
    row_major float3x4 transform;
    uint instanceCustomIndexAndMask;
    uint instanceShaderBindingTableRecordOffsetAndFlags;
    uint64_t accelerationStructureReference;

    uint instanceID() {
        return instanceCustomIndexAndMask & 0x00FFFFFF;
    }
};

struct Geometry {
    uint meshIdx;
    uint materialIdx;
    bool sampled;
};

struct Mesh {
    uint64_t positionAddress;
    uint64_t texcoordAddress; // may be zero, for no texcoords
    uint64_t normalAddress; // may be zero, for no vertex normals

    uint64_t indexAddress;
};

enum class MaterialType : uint {
    Glass,
    Lambert,
    PerfectMirror,
    StandardPBR,
};

struct MaterialVariantData {
    // all materials have these two
    uint normal;
    uint emissive;

    // then material specific stuff
    // find appropriate thing to decode from address using `type`
    MaterialType type;
    uint64_t materialAddress;
};

struct World {
    StructuredBuffer<Instance> instances;
    StructuredBuffer<row_major float3x4> worldToInstance;

    StructuredBuffer<Mesh> meshes;
    StructuredBuffer<Geometry> geometries;

    StructuredBuffer<MaterialVariantData> materials;

    bool indexed_attributes;
    bool two_component_normal_texture;

    Geometry getGeometry(uint instanceID, uint geometryIndex) {
        return geometries[NonUniformResourceIndex(instanceID + geometryIndex)];
    }

    uint meshIdx(uint instanceID, uint geometryIndex) {
        return getGeometry(instanceID, geometryIndex).meshIdx;
    }

    uint materialIdx(uint instanceID, uint geometryIndex) {
        return getGeometry(instanceID, geometryIndex).materialIdx;
    }
};

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

struct MeshAttributes {
    float3 position;
    float2 texcoord;

    Frame triangleFrame; // from triangle positions
    Frame frame; // from vertex attributes

    static MeshAttributes lookupAndInterpolate(World world, uint instanceIndex, uint geometryIndex, uint primitiveIndex, float2 attribs) {
        uint instanceID = world.instances[instanceIndex].instanceID();
        uint meshIndex = world.meshIdx(instanceID, geometryIndex);
        Mesh mesh = world.meshes[NonUniformResourceIndex(meshIndex)];
        float3 barycentrics = float3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);

        MeshAttributes attrs;

        uint3 ind = vk::RawBufferLoad<uint3>(mesh.indexAddress + sizeof(uint3) * primitiveIndex);

        // positions always available
        float3 p0 = loadPosition(mesh.positionAddress, ind.x);
        float3 p1 = loadPosition(mesh.positionAddress, ind.y);
        float3 p2 = loadPosition(mesh.positionAddress, ind.z);
        attrs.position = interpolate(barycentrics, p0, p1, p2);

        uint3 attr_ind = world.indexed_attributes ? ind : float3(primitiveIndex * 3 + 0, primitiveIndex * 3 + 1, primitiveIndex * 3 + 2);

        // texcoords optional
        float2 t0, t1, t2;
        if (mesh.texcoordAddress != 0) {
            t0 = loadTexcoord(mesh.texcoordAddress, attr_ind.x);
            t1 = loadTexcoord(mesh.texcoordAddress, attr_ind.y);
            t2 = loadTexcoord(mesh.texcoordAddress, attr_ind.z);
        } else {
            // textures should be constant in this case
            t0 = float2(0, 0);
            t1 = float2(1, 0);
            t2 = float2(1, 1);
        }
        attrs.texcoord = interpolate(barycentrics, t0, t1, t2);

        getTangentBitangent(p0, p1, p2, t0, t1, t2, attrs.triangleFrame.s, attrs.triangleFrame.t);
        attrs.triangleFrame.n = normalize(cross(p0 - p2, p1 - p2));
        attrs.triangleFrame.reorthogonalize();

        // normals optional
        if (mesh.normalAddress != 0) {
            float3 n0 = loadNormal(mesh.normalAddress, attr_ind.x);
            float3 n1 = loadNormal(mesh.normalAddress, attr_ind.y);
            float3 n2 = loadNormal(mesh.normalAddress, attr_ind.z);
            attrs.frame = attrs.triangleFrame;
            attrs.frame.n = normalize(interpolate(barycentrics, n0, n1, n2));
            attrs.frame.reorthogonalize();
        } else {
            // just use one from triangle
            attrs.frame = attrs.triangleFrame;
        }

        return attrs;
    }

    MeshAttributes inWorld(World world, uint instanceIndex) {
        float3x4 toWorld = world.instances[NonUniformResourceIndex(instanceIndex)].transform;
        float3x4 toMesh = world.worldToInstance[NonUniformResourceIndex(instanceIndex)];

        position = mul(toWorld, float4(position, 1.0));

        triangleFrame = triangleFrame.inSpace(transpose(toMesh));
        frame = frame.inSpace(transpose(toMesh));

        return this;
    }
};
