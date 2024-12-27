#pragma once

#include "../utils/math.hlsl"
#include "ray.hlsl"

struct [raypayload] Intersection {
    uint instanceIndex : read(caller) : write(closesthit, miss);  // MAX_UINT for no hit
    uint geometryIndex : read(caller) : write(closesthit);
    uint primitiveIndex : read(caller) : write(closesthit);
    float2 barycentrics : read(caller) : write(closesthit);

    static Intersection createMiss() {
        Intersection its;
        its.instanceIndex = MAX_UINT;
        return its;
    }

    static Intersection find(RaytracingAccelerationStructure accel, Ray ray) {
        return Intersection::find(accel, ray, 1.#INF);
    }

    // traces a ray to find the nearest intersection where tHit < tMax
    static Intersection find(RaytracingAccelerationStructure accel, Ray ray, float tmax) {
        Intersection its;
        TraceRay(accel, RAY_FLAG_FORCE_OPAQUE, 0xFF, 0, 0, 0, ray.desc(0, tmax), its);
        return its;
    }

    bool hit() {
        return instanceIndex != MAX_UINT;
    }
};

struct [raypayload] ShadowIntersection {
    bool inShadow : read(caller) : write(miss);

    // traces a shadow ray, returning whether it hit geometry
    static bool hit(RaytracingAccelerationStructure accel, Ray ray, float maxDistance) {
        const uint shadowTraceFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_FORCE_OPAQUE | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER;

        ShadowIntersection its;
        its.inShadow = true;
        TraceRay(accel, shadowTraceFlags, 0xFF, 0, 0, 1, ray.desc(0, maxDistance), its);
        return its.inShadow;
    }
};

