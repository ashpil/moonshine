#include "../../utils/helpers.hlsl"
#include "../world.hlsl"

[[vk::binding(0, 0)]] RWStructuredBuffer<float> levels;
[[vk::binding(1, 0)]] StructuredBuffer<Instance> instances;
[[vk::binding(2, 0)]] RWStructuredBuffer<uint> dGeometryToTrianglePowerOffset;
[[vk::binding(3, 0)]] RWStructuredBuffer<uint> emissiveTriangleCount;

struct PushConsts {
	uint instanceIndex;
	uint geometryIndex;
	uint triangleCount;
	uint srcLevelOffset;
	uint dstLevelOffset;
};
[[vk::push_constant]] PushConsts pushConsts;

[numthreads(32, 1, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
	const uint dstIndex = dispatchXYZ.x;
	const uint dstLevelSize = pushConsts.srcLevelOffset - pushConsts.dstLevelOffset;

	if (any(dstIndex >= dstLevelSize)) return;

	if (dstLevelSize == 1) {
		const float newSum = levels[pushConsts.srcLevelOffset + 2 * dstIndex + 0] + levels[pushConsts.srcLevelOffset + 2 * dstIndex + 1];
		const float oldSum = levels[pushConsts.dstLevelOffset + dstIndex];
		// if this conditional fails it means this mesh is not actually emissive at all
		// in this case, not adding it to our sum will effectively cull it
		if (newSum != oldSum) {
			const uint flatGeometryIndex = pushConsts.instanceIndex + pushConsts.geometryIndex;
			const uint existingOffset = dGeometryToTrianglePowerOffset[flatGeometryIndex];

			// only update offset and emissive triangle count if this geometry is not already tracked for emissive light
			const uint invalidOffset = 0xFFFFFFFF;
			if (existingOffset == invalidOffset) {
				// TODO: emissiveTriangleCount has a relatively small (32k maximum), which will probably only show up as a crash.
				// need to make maximum higher so this isn't a feasible problem.
				dGeometryToTrianglePowerOffset[flatGeometryIndex] = emissiveTriangleCount[0];
				emissiveTriangleCount[0] += pushConsts.triangleCount;
			}
		}
	}

	levels[pushConsts.dstLevelOffset + dstIndex] = levels[pushConsts.srcLevelOffset + 2 * dstIndex + 0]
												 + levels[pushConsts.srcLevelOffset + 2 * dstIndex + 1];
}