#pragma once

#include "math.hlsl"

struct [raypayload] Intersection {
    uint instanceID : read(caller) : write(closesthit, miss); // MAX_UINT for no hit -- currently only 24 bits actually ever used
    uint instanceIndex : read(caller) : write(closesthit);
    uint geometryIndex : read(caller) : write(closesthit);
    uint primitiveIndex : read(caller) : write(closesthit);
    float2 attribs : read(caller) : write(closesthit);

    static Intersection createMiss() {
        Intersection its;
        its.instanceID = MAX_UINT;
        return its;
    }

    bool hit() {
        return instanceID != MAX_UINT;
    }
};

