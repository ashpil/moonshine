#include "payload.hlsl"
#include "geometry.hlsl"

[shader("closesthit")]
void main(inout Payload payload, in float2 attribs) {
    uint materialIndex = materialIdx(InstanceID(), GeometryIndex());
    uint meshIndex = meshIdx(InstanceID(), GeometryIndex());

    Mesh mesh = meshes[NonUniformResourceIndex(meshIndex)];

    float3 barycentrics = float3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);
    MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(mesh, barycentrics, PrimitiveIndex());
    attrs = attrs.inWorld(InstanceIndex());
   
    payload.texcoord = attrs.texcoord;
    payload.position = attrs.position;
    payload.normal = attrs.normal;
    payload.tangent = attrs.tangent;

    payload.done = false;
    payload.materialIndex = materialIndex;
}

