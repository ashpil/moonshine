#pragma once

#include "reflection_frame.hlsl"
#include "material.hlsl"

struct Instance { // same required by vulkan on host side
    row_major float3x4 transform;
    uint instanceCustomIndex : 24;
    uint mask : 8;
    uint instanceShaderBindingTableRecordOffset : 24;
    uint flags : 8;
    uint64_t accelerationStructureReference;

    static const uint THIN_MASK = 0b10000000;

    bool thin() {
        return mask == THIN_MASK;
    }

    uint priority() {
        return firstbithigh(mask) + 1;
    }
};

struct Geometry {
    uint meshIndex;
    uint materialIndex;
};

struct Mesh {
    uint64_t positionAddress;
    uint64_t texcoordAddress; // may be zero, for no texcoords
    uint64_t normalAddress; // may be zero, for no vertex normals

    uint64_t indexAddress; // may be zero, for unindexed geometry
};

struct SurfacePoint {
    float3 position;
    float2 texcoord;

    Frame triangleFrame; // from triangle positions
    Frame frame; // from vertex attributes

    float spawnOffset; // minimum offset along normal that a ray will not intersect
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

void getTangentBitangent(float3 positions[3], float2 texcoords[3], out float3 tangent, out float3 bitangent) {
    float2 deltaT10 = texcoords[1] - texcoords[0];
    float2 deltaT20 = texcoords[2] - texcoords[0];

    float3 deltaP10 = positions[1] - positions[0];
    float3 deltaP20 = positions[2] - positions[0];

    float det = deltaT10.x * deltaT20.y - deltaT10.y * deltaT20.x;
    if (det == 0.0) {
        coordinateSystem(normalize(cross(deltaP10, deltaP20)), tangent, bitangent);
    } else {
        tangent = normalize((deltaT20.y * deltaP10 - deltaT10.y * deltaP20) / det);
        bitangent = normalize((-deltaT20.x * deltaP10 + deltaT10.x * deltaP20) / det);
    }
}

template <typename T>
T interpolate(float3 barycentrics, T v[3]) {
    return barycentrics.x * v[0] + barycentrics.y * v[1] + barycentrics.z * v[2];
}

struct TriangleLocalSpace {
    float3 positions[3];
    float3 normals[3];
    float2 texcoords[3];

    // TODO: currently this does both barycentric evaluation and local to world
    // conversion. there's probably a way to decouple this into two functions
    SurfacePoint surfacePoint(const float2 attribs, const float3x4 toWorld, const float3x4 toMesh) {
        SurfacePoint surface;

        const float3 barycentrics = float3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);

        const float3 edge1 = positions[1] - positions[0];
        const float3 edge2 = positions[2] - positions[0];
        surface.position = positions[0] + ((attribs.x * edge1) + (attribs.y * edge2));

        surface.texcoord = interpolate(barycentrics, texcoords);

        getTangentBitangent(positions, texcoords, surface.triangleFrame.s, surface.triangleFrame.t);
        surface.triangleFrame.n = normalize(cross(edge1, edge2));
        surface.triangleFrame.reorthogonalize();

        surface.frame = surface.triangleFrame;
        surface.frame.n = normalize(interpolate(barycentrics, normals));
        surface.frame.reorthogonalize();

        const float3 worldPosition = mul(toWorld, float4(surface.position, 1.0));

        // https://developer.nvidia.com/blog/solving-self-intersection-artifacts-in-directx-raytracing/
        {
            float3 wldNormal = mul(transpose((float3x3)toMesh), surface.triangleFrame.n);

            const float wldScale = rsqrt(dot(wldNormal, wldNormal));
            wldNormal = mul(wldScale, wldNormal);

            // nvidia magic constants
            const float c0 = 5.9604644775390625E-8f;
            const float c1 = 1.788139769587360206060111522674560546875E-7f;
            const float c2 = 1.19209317972490680404007434844970703125E-7f;

            const float3 extent3 = abs(edge1) + abs(edge2) + abs(edge1 - edge2);
            const float extent = max(max(extent3.x, extent3.y), extent3.z);

            float3 objErr = c0 * abs(positions[0]) + mul(c1, extent);

            const float3 wldErr = c1 * mul(abs((float3x3)toWorld), abs(surface.position)) + mul(c2, abs(transpose(toWorld)[3]));

            objErr += c2 * mul(abs(toMesh), float4(abs(worldPosition), 1));

            const float wldOffset = dot(wldErr, abs(wldNormal));
            const float objOffset = dot(objErr, abs(surface.triangleFrame.n));

            surface.spawnOffset = wldScale * objOffset + wldOffset;
        }

        // convert to world space
        {
            surface.position = worldPosition;

            surface.triangleFrame = surface.triangleFrame.inSpace(transpose(toMesh));
            surface.frame = surface.frame.inSpace(transpose(toMesh));
        }

        return surface;
    }

    float area(const float3x4 toWorld) {
        float3 p0 = mul(toWorld, float4(positions[0], 1.0));
        float3 p1 = mul(toWorld, float4(positions[1], 1.0));
        float3 p2 = mul(toWorld, float4(positions[2], 1.0));

        return length(cross(p1 - p0, p2 - p0)) / 2.0;
    }
};

struct World {
    StructuredBuffer<Instance> instances;
    StructuredBuffer<row_major float3x4> worldToInstance;

    StructuredBuffer<uint> modelToGeometryOffset;
    StructuredBuffer<Mesh> meshes;
    StructuredBuffer<Geometry> geometries;

    StructuredBuffer<Material> materials;

    Mesh mesh(uint instanceIndex, uint geometryIndex) {
        const uint instanceID = instances[instanceIndex].instanceCustomIndex;
        const Geometry geometry = geometries[NonUniformResourceIndex(modelToGeometryOffset[instanceID] + geometryIndex)];
        return meshes[NonUniformResourceIndex(geometry.meshIndex)];
    }

    Material material(uint instanceIndex, uint geometryIndex) {
        const uint instanceID = instances[instanceIndex].instanceCustomIndex;
        const Geometry geometry = geometries[NonUniformResourceIndex(modelToGeometryOffset[instanceID] + geometryIndex)];
        return materials[NonUniformResourceIndex(geometry.materialIndex)];
    }

    bool thin(uint instanceIndex) {
        return instances[instanceIndex].thin();
    }

    uint priority(uint instanceIndex) {
        return instances[instanceIndex].priority();
    }

    float triangleArea(uint instanceIndex, uint geometryIndex, uint primitiveIndex) {
        const float3x4 toWorld = instances[NonUniformResourceIndex(instanceIndex)].transform;
        return triangleLocalSpace(instanceIndex, geometryIndex, primitiveIndex).area(toWorld);
    }

    TriangleLocalSpace triangleLocalSpace(uint instanceIndex, uint geometryIndex, uint primitiveIndex) {
        TriangleLocalSpace t;

        Mesh mesh = this.mesh(instanceIndex, geometryIndex);

        const uint3 ind = mesh.indexAddress != 0 ? vk::RawBufferLoad<uint3>(mesh.indexAddress + sizeof(uint3) * primitiveIndex) : float3(primitiveIndex * 3 + 0, primitiveIndex * 3 + 1, primitiveIndex * 3 + 2);

        // positions always available
        t.positions[0] = loadPosition(mesh.positionAddress, ind.x);
        t.positions[1] = loadPosition(mesh.positionAddress, ind.y);
        t.positions[2] = loadPosition(mesh.positionAddress, ind.z);

        // texcoords optional
        if (mesh.texcoordAddress != 0) {
            t.texcoords[0] = loadTexcoord(mesh.texcoordAddress, ind.x);
            t.texcoords[1] = loadTexcoord(mesh.texcoordAddress, ind.y);
            t.texcoords[2] = loadTexcoord(mesh.texcoordAddress, ind.z);
        } else {
            // sane defaults for constant textures
            t.texcoords[0] = float2(0, 0);
            t.texcoords[1] = float2(1, 0);
            t.texcoords[2] = float2(1, 1);
        }

        // normals optional
        if (mesh.normalAddress != 0) {
            t.normals[0] = loadNormal(mesh.normalAddress, ind.x);
            t.normals[1] = loadNormal(mesh.normalAddress, ind.y);
            t.normals[2] = loadNormal(mesh.normalAddress, ind.z);
        } else {
            // use triangle normal
            const float3 normal = normalize(cross(t.positions[1] - t.positions[0], t.positions[2] - t.positions[0]));
            t.normals[0] = normal;
            t.normals[1] = normal;
            t.normals[2] = normal;
        }

        return t;
    }

    float3x4 toWorld(uint instanceIndex) {
        return instances[NonUniformResourceIndex(instanceIndex)].transform;
    }

    float3x4 toMesh(uint instanceIndex) {
        return worldToInstance[NonUniformResourceIndex(instanceIndex)];
    }

    SurfacePoint surfacePoint(uint instanceIndex, uint geometryIndex, uint primitiveIndex, float2 attribs) {
        return triangleLocalSpace(instanceIndex, geometryIndex, primitiveIndex).surfacePoint(attribs, toWorld(instanceIndex), toMesh(instanceIndex));
    }
};
