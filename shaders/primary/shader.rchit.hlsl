#include "payload.hlsl"

[shader("closesthit")]
void main(inout Payload payload, in float2 attribs) {
    payload.instanceID = InstanceID();
    payload.instanceIndex = InstanceIndex();
    payload.geometryIndex = GeometryIndex();
    payload.primitiveIndex = PrimitiveIndex();
    payload.attribs = attribs;
}

