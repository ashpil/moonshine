#include "payload.hlsl"
#include "geometry.hlsl"

[shader("closesthit")]
void main(inout Payload payload, in float2 attribs) {
    uint materialIndex = materialIdx(InstanceID(), GeometryIndex());
    uint meshIndex = meshIdx(InstanceID(), GeometryIndex());

    float3 barycentrics = float3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);
    Mesh mesh = meshes[NonUniformResourceIndex(meshIndex)];
    Attributes attrs = Attributes::lookupAndInterpolate(mesh, barycentrics, PrimitiveIndex());
   
    float3x4 toWorld = instanceToWorld[NonUniformResourceIndex(InstanceIndex())];
    float3x4 toInstance = worldToInstance[NonUniformResourceIndex(InstanceIndex())];
    payload.texcoord = attrs.texcoord;
    payload.position = mul(toWorld, float4(attrs.position, 1.0));
    payload.tangent = normalize(mul(transpose(toInstance), attrs.tangent).xyz);
    payload.normal = normalize(mul(transpose(toInstance), attrs.normal).xyz);

    payload.done = false;
    payload.materialIndex = materialIndex;
}

