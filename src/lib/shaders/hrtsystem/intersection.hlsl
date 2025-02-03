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

    static Intersection find(RaytracingAccelerationStructure accel, Ray ray, float tmax) {
        return Intersection::find(accel, ray, tmax, 0xFF);
    }

    static Intersection find(RaytracingAccelerationStructure accel, Ray ray, float tmax, uint mask) {
        Intersection its;
        TraceRay(accel, RAY_FLAG_FORCE_OPAQUE, mask, 0, 0, 0, ray.desc(0, tmax), its);
        return its;
    }

    bool hit() {
        return instanceIndex != MAX_UINT;
    }
};

struct [raypayload] ShadowIntersection {
    bool inShadow : read(caller) : write(miss);

    static bool hit(RaytracingAccelerationStructure accel, Ray ray, float tmax) {
        return ShadowIntersection::hit(accel, ray, tmax, 0xFF);
    }

    static bool hit(RaytracingAccelerationStructure accel, Ray ray, float tmax, uint mask) {
        const uint shadowTraceFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_FORCE_OPAQUE | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER;

        ShadowIntersection its;
        its.inShadow = true;
        TraceRay(accel, shadowTraceFlags, mask, 0, 0, 1, ray.desc(0, tmax), its);
        return its.inShadow;
    }
};

