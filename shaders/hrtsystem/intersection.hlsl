#pragma once

#include "../utils/math.hlsl"

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

    // traces a ray to find the nearest intersection
    static Intersection find(RaytracingAccelerationStructure accel, RayDesc ray) {
        Intersection its;
        TraceRay(accel, RAY_FLAG_FORCE_OPAQUE, 0xFF, 0, 0, 0, ray, its);
        return its;
    }

    bool hit() {
        return instanceIndex != MAX_UINT;
    }
};

struct [raypayload] ShadowIntersection {
    bool inShadow : read(caller) : write(miss);

    // traces a shadow ray, returning whether it hit geometry
    static bool hit(RaytracingAccelerationStructure accel, float3 origin, float3 direction, float tmax) {
        const uint shadowTraceFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_FORCE_OPAQUE | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER;
        
        RayDesc ray;
        ray.Origin = origin;
        ray.Direction = direction;
        ray.TMin = 0.0;
        ray.TMax = tmax;

        ShadowIntersection its;
        its.inShadow = true;
        TraceRay(accel, shadowTraceFlags, 0xFF, 0, 0, 1, ray, its);
        return its.inShadow;
    }
};

