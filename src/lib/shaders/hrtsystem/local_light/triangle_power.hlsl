#include "../world.hlsl"

[[vk::binding(0, 0)]] StructuredBuffer<Mesh> dMeshes;
[[vk::binding(1, 0)]] StructuredBuffer<Material> dMaterials;

// dst
[[vk::binding(2, 0)]] RWStructuredBuffer<float3x3> dstPower;

// mesh info
struct PushConsts {
	uint meshIndex;
	uint materialIndex;
	uint triangleCount;
	uint dstOffset;
};
[[vk::push_constant]] PushConsts pushConsts;

[numthreads(32, 1, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
	const uint srcPrimitive = dispatchXYZ.x;

	if (srcPrimitive >= pushConsts.triangleCount) {
		if (pushConsts.triangleCount != 1 && pushConsts.triangleCount % 2 == 1 && srcPrimitive == pushConsts.triangleCount) {
			// may be one element of padding, which should be zeroed
			dstPower[pushConsts.dstOffset + srcPrimitive] = 0;
		}
		return;
	}

	const TriangleLocalSpace tri = dMeshes[pushConsts.meshIndex].triangleLocalSpace(srcPrimitive);
	const Material material = dMaterials[pushConsts.materialIndex];

	float3 totalEmissive = 0;

	const uint samplesPerDimension = 8;
	for (uint i = 0; i < samplesPerDimension; i++) {
		for (uint j = 0; j < samplesPerDimension; j++) {
			const float2 barycentrics = squareToTriangle(float2(i, j) / float(samplesPerDimension));
			const float2 texcoord = interpolate(float3(1.0 - barycentrics.x - barycentrics.y, barycentrics.x, barycentrics.y), tri.texcoords);
			totalEmissive += dTextures[NonUniformResourceIndex(material.emissive)].SampleLevel(dTextureSampler, texcoord, 0).rgb;
		}
	}

	const float3 averageEmissive = totalEmissive / float(samplesPerDimension * samplesPerDimension);
	const float3 projectedArea = tri.bivector() / 2.0;
	const float3x3 power = PI * float3x3(
		abs(projectedArea.x) * averageEmissive,
		abs(projectedArea.y) * averageEmissive,
		abs(projectedArea.z) * averageEmissive
	);

	dstPower[pushConsts.dstOffset + srcPrimitive] = power;
}