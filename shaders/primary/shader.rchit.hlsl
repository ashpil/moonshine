#include "payload.hlsl"
#include "geometry.hlsl"

[shader("closesthit")]
void main(inout Payload payload, in float2 attribs) {
    uint materialIndex = materialIdx(InstanceID(), GeometryIndex());
    uint meshIndex = meshIdx(InstanceID(), GeometryIndex());

    MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(meshIndex, PrimitiveIndex(), attribs);
    attrs = attrs.inWorld(InstanceIndex());
   
    payload.texcoord = attrs.texcoord;
    payload.position = attrs.position;
    payload.normal = attrs.normal;
    payload.tangent = attrs.tangent;

    payload.done = false;
    payload.materialIndex = materialIndex;
}

