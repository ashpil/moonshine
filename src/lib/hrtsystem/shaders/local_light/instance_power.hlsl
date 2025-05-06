#include "../world.hlsl"

[[vk::binding(0, 0)]] StructuredBuffer<Instance> dInstances;
[[vk::binding(1, 0)]] StructuredBuffer<row_major float3x4> dWorldToInstance;
[[vk::binding(2, 0)]] StructuredBuffer<Model> dModels;

// dst
[[vk::binding(3, 0)]] RWStructuredBuffer<float3> dstPower;

struct PushConsts {
	uint instanceCount;
	uint dstOffset;
};
[[vk::push_constant]] PushConsts pushConsts;

[numthreads(32, 1, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
	const uint srcInstance = dispatchXYZ.x;

	if (srcInstance >= pushConsts.instanceCount) {
		if (pushConsts.instanceCount != 1 && pushConsts.instanceCount % 2 == 1 && srcInstance == pushConsts.instanceCount) {
			// may be one element of padding, which should be zeroed
			dstPower[pushConsts.dstOffset + srcInstance] = 0;
		}
		return;
	}

	const Instance instance = dInstances[srcInstance];
	const Model model = dModels[instance.instanceCustomIndex];

    const float3x3 toWorld = (float3x3)instance.transform;
    const float3x3 toLocal = (float3x3)dWorldToInstance[srcInstance];
	const float3x3 cofactor = abs(transpose(toLocal) * determinant(toWorld));

	const float3x3 modelPower = transpose(vk::RawBufferLoad<float3x3>(model.geometryPowersAddress));
	dstPower[pushConsts.dstOffset + srcInstance] = float3(
		normL1(mul(cofactor, modelPower[0])),
		normL1(mul(cofactor, modelPower[1])),
		normL1(mul(cofactor, modelPower[2]))
	);
}