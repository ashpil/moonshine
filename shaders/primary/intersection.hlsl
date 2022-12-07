#pragma once

#include "math.hlsl"

struct [raypayload] Intersection {
    uint instanceIndex : read(caller) : write(closesthit, miss);  // MAX_UINT for no hit
    uint geometryIndex : read(caller) : write(closesthit);
    uint primitiveIndex : read(caller) : write(closesthit);
    float2 attribs : read(caller) : write(closesthit);

    static Intersection createMiss() {
        Intersection its;
        its.instanceIndex = MAX_UINT;
        return its;
    }

    // traces a ray to find the nearest intersection
    static Intersection find(RayDesc ray) {
        Intersection its;
        TraceRay(dTLAS, RAY_FLAG_FORCE_OPAQUE, 0xFF, 0, 0, 0, ray, its);
        return its;
    }

    bool hit() {
        return instanceIndex != MAX_UINT;
    }
};

struct [raypayload] ShadowIntersection {
    bool inShadow : read(caller) : write(miss);

    // traces a shadow ray, returning whether it hit geometry
    static bool hit(RayDesc ray) {
        const uint shadowTraceFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_FORCE_OPAQUE | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER;

        ShadowIntersection its;
        its.inShadow = true;
        TraceRay(dTLAS, shadowTraceFlags, 0xFF, 0, 0, 1, ray, its);
        return its.inShadow;
    }
};

