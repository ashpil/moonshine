#pragma once

#include "../../shaders/utils/math.hlsl"
#include "ray.hlsl"

struct Intersection {
    uint instanceIndex;
    uint geometryIndex;
    uint primitiveIndex;
    float2 barycentrics;

    static Intersection create(uint instanceIndex, uint geometryIndex, uint primitiveIndex, float2 barycentrics) {
        Intersection its;
        its.instanceIndex = instanceIndex;
        its.geometryIndex = geometryIndex;
        its.primitiveIndex = primitiveIndex;
        its.barycentrics = barycentrics;
        return its;
    }

    static Intersection createMiss() {
        Intersection its;
        its.instanceIndex = MAX_UINT;
        return its;
    }

    static Intersection find(RaytracingAccelerationStructure accel, Ray ray) {
        return Intersection::find(accel, ray, 1.#INF);
    }

    static Intersection find(RaytracingAccelerationStructure accel, Ray ray, float tmax) {
        return Intersection::find(accel, ray, tmax, 0xFF);
    }

    static Intersection find(RaytracingAccelerationStructure accel, Ray ray, float tmax, uint mask) {
        RayQuery<RAY_FLAG_FORCE_OPAQUE | RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES> q;
        q.TraceRayInline(accel, 0, mask, ray.desc(0, tmax));

        while (q.Proceed()) {};

        if (q.CommittedStatus() != COMMITTED_TRIANGLE_HIT) {
            return Intersection::createMiss();
        }

        // for some reason dxc won't let me put an else here :think:
        return Intersection::create(
            q.CommittedInstanceIndex(),
            q.CommittedGeometryIndex(),
            q.CommittedPrimitiveIndex(),
            q.CommittedTriangleBarycentrics()
        );
    }

    bool hit() {
        return instanceIndex != MAX_UINT;
    }
};

struct ShadowIntersection {
    bool inShadow;

    static bool hit(RaytracingAccelerationStructure accel, Ray ray, float tmax) {
        return ShadowIntersection::hit(accel, ray, tmax, 0xFF);
    }

    static bool hit(RaytracingAccelerationStructure accel, Ray ray, float tmax, uint mask) {
        RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_FORCE_OPAQUE> q;
        q.TraceRayInline(accel, 0, mask, ray.desc(0, tmax));
        q.Proceed();

        ShadowIntersection its;
        its.inShadow = q.CommittedStatus() == COMMITTED_TRIANGLE_HIT;
        return its.inShadow;
    }
};
