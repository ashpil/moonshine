#include "../world.hlsl"

[[vk::binding(0, 0)]] StructuredBuffer<Geometry> dGeometries;

// dst
[[vk::binding(1, 0)]] RWStructuredBuffer<float3x3> dstPower;

// mesh info
struct PushConsts {
	uint geometryCount;
	uint srcOffset;
	uint dstOffset;
};
[[vk::push_constant]] PushConsts pushConsts;

[numthreads(32, 1, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
	const uint srcIdx = dispatchXYZ.x;

	if (srcIdx >= pushConsts.geometryCount) {
		if (pushConsts.geometryCount != 1 && pushConsts.geometryCount % 2 == 1 && srcIdx == pushConsts.geometryCount) {
			// may be one element of padding, which should be zeroed
			dstPower[pushConsts.dstOffset + srcIdx] = 0;
		}
		return;
	}

	const Geometry geometry = dGeometries[pushConsts.srcOffset + srcIdx];
	const float3x3 power = vk::RawBufferLoad<float3x3>(geometry.trianglePowersAddress); // TODO: transform

	dstPower[pushConsts.dstOffset + srcIdx] = power;
}