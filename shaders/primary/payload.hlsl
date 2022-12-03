#include "math.hlsl"

struct [raypayload] Payload {
    uint instanceID : read(caller) : write(closesthit, miss); // MAX_UINT for no hit -- currently only 24 bits actually ever used
    uint instanceIndex : read(caller) : write(closesthit);
    uint geometryIndex : read(caller) : write(closesthit);
    uint primitiveIndex : read(caller) : write(closesthit);
    float2 attribs : read(caller) : write(closesthit);

    bool done() {
        return instanceID == MAX_UINT;
    }
};

