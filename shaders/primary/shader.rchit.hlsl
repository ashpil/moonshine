#include "intersection.hlsl"

[shader("closesthit")]
void main(inout Intersection its, in float2 attribs) {
    its.instanceID = InstanceID();
    its.instanceIndex = InstanceIndex();
    its.geometryIndex = GeometryIndex();
    its.primitiveIndex = PrimitiveIndex();
    its.attribs = attribs;
}

