#pragma once

#include "world.hlsl"
#include "material.hlsl"

struct LightSample {
    float3 dirWs;
    float3 radiance;
    float pdf;
};

struct LightEval {
    float3 radiance;
    float pdf;
};

template <class Data>
struct AliasEntry {
    uint alias;
    float select;
    Data data;
};


interface Light {
    // samples a light direction based on given position and geometric normal, returning
    // radiance at that point from light and pdf of this direction + radiance
    //
    // pdf is with respect to obstructed solid angle, that is, this traces a ray
    // TODO: should pdf be unobstructed?
    LightSample sample(RaytracingAccelerationStructure accel, float3 positionWs, float3 triangleNormalDirWs, float2 square);
};

struct EnvMap : Light {
    Texture2D<float3> texture;
    StructuredBuffer<AliasEntry<float> > marginalAlias; // size: texture.height
    StructuredBuffer<AliasEntry<float> > conditionalAlias; // size: texture.height * texture.width

    static EnvMap create(Texture2D<float3> texture, StructuredBuffer<AliasEntry<float> > marginalAlias, StructuredBuffer<AliasEntry<float> > conditionalAlias) {
        EnvMap map;
        map.texture = texture;
        map.marginalAlias = marginalAlias;
        map.conditionalAlias = conditionalAlias;
        return map;
    }

    float sample2D(inout float2 uv, out uint2 result) {
        uint2 size;
        texture.GetDimensions(size.x, size.y);

        float pdf_y = sampleAlias<float, AliasEntry<float> >(marginalAlias, size.y, 0, uv.y, result.y);
        float pdf_x = sampleAlias<float, AliasEntry<float> >(conditionalAlias, size.x, result.y * size.x, uv.x, result.x);

        return pdf_x * pdf_y * float(size.x * size.y);
    }

    LightSample sample(RaytracingAccelerationStructure accel, float3 positionWs, float3 normalWs, float2 rand) {
        uint2 size;
        texture.GetDimensions(size.x, size.y);

        uint2 discreteuv;
        float pdf2d = sample2D(rand, discreteuv);
        float2 uv = (float2(discreteuv) + rand) / size;

        float phi = uv.x * 2.0 * PI;
        float theta = uv.y * PI;

        float sinTheta = sin(theta);

        LightSample lightSample;
        lightSample.pdf = sinTheta != 0.0 ? pdf2d / (2.0 * PI * PI * sinTheta) : 0.0;
        lightSample.radiance = texture[discreteuv];
        lightSample.dirWs = sphericalToCartesian(sinTheta, cos(theta), phi);

        if (lightSample.pdf > 0.0 && ShadowIntersection::hit(accel, offsetAlongNormal(positionWs, faceForward(normalWs, lightSample.dirWs)), lightSample.dirWs, INFINITY)) {
            lightSample.pdf = 0.0;
        }

        return lightSample;
    }

    // pdf is with respect to solid angle (no trace)
    LightEval eval(float3 dirWs) {
        float2 phiTheta = cartesianToSpherical(dirWs);
        float2 uv = phiTheta / float2(2 * PI, PI);

        uint2 size;
        texture.GetDimensions(size.x, size.y);
        uint2 coords = clamp(uint2(uv * size), uint2(0, 0), size);
        float pdf2d = marginalAlias[coords.y].data * conditionalAlias[coords.y * size.x + coords.x].data * float(size.x * size.y);
        float sinTheta = sin(phiTheta.y);

        LightEval l;
        l.pdf = sinTheta != 0.0 ? pdf2d / (2.0 * PI * PI * sinTheta) : 0.0;
        l.radiance = texture[coords];
        return l;
    }

    float3 incomingRadiance(float3 dirWs) {
        float2 phiTheta = cartesianToSpherical(dirWs);
        float2 uv = phiTheta / float2(2 * PI, PI);
        return texture.SampleLevel(dTextureSampler, uv, 0);
    }
};

float areaMeasureToSolidAngleMeasure(float3 pos1, float3 pos2, float3 dir1, float3 dir2) {
    float r2 = dot(pos1 - pos2, pos1 - pos2);
    float lightCos = dot(-dir1, dir2);

    return lightCos > 0.0f ? r2 / lightCos : 0.0f;
}

struct LightAliasData {
    uint instanceIndex;
    uint geometryIndex;
    uint primitiveIndex;
};

// all mesh lights in scene
struct MeshLights : Light {
    StructuredBuffer<AliasEntry<LightAliasData> > aliasTable;
    World world;

    static MeshLights create(StructuredBuffer<AliasEntry<LightAliasData> > aliasTable, World world) {
        MeshLights lights;
        lights.aliasTable = aliasTable;
        lights.world = world;
        return lights;
    }

    LightSample sample(RaytracingAccelerationStructure accel, float3 positionWs, float3 triangleNormalDirWs, float2 rand) {
        LightSample lightSample;
        lightSample.pdf = 0.0;

        uint entryCount = aliasTable[0].alias;
        float sum = aliasTable[0].select;
        if (entryCount == 0 || sum == 0) return lightSample;

        uint idx;
        LightAliasData data = sampleAlias<LightAliasData, AliasEntry<LightAliasData> >(aliasTable, entryCount, 1, rand.x, idx);
        uint instanceID = world.instances[data.instanceIndex].instanceID();

        float2 barycentrics = squareToTriangle(rand);
        MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(world, data.instanceIndex, data.geometryIndex, data.primitiveIndex, barycentrics).inWorld(world, data.instanceIndex);

        lightSample.radiance = getEmissive(world, world.materialIdx(instanceID, data.geometryIndex), attrs.texcoord);
        lightSample.dirWs = normalize(attrs.position - positionWs);
        lightSample.pdf = areaMeasureToSolidAngleMeasure(attrs.position, positionWs, lightSample.dirWs, attrs.triangleFrame.n) / sum;

        // compute precise ray endpoints
        float3 offsetLightPositionWs = offsetAlongNormal(attrs.position, attrs.triangleFrame.n);
        float3 offsetShadingPositionWs = offsetAlongNormal(positionWs, faceForward(triangleNormalDirWs, lightSample.dirWs));
        float tmax = distance(offsetLightPositionWs, offsetShadingPositionWs);

        if (lightSample.pdf > 0.0 && ShadowIntersection::hit(accel, offsetShadingPositionWs, normalize(offsetLightPositionWs - offsetShadingPositionWs), tmax)) {
            lightSample.pdf = 0.0;
        }
        return lightSample;
    }
};
