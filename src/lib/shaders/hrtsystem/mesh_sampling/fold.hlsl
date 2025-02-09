#include "../../utils/helpers.hlsl"
#include "../world.hlsl"

[[vk::binding(0, 0)]] Texture1D<float> srcMip;
[[vk::binding(1, 0)]] RWTexture1D<float> dstMip;
[[vk::binding(2, 0)]] StructuredBuffer<Instance> instances;
[[vk::binding(3, 0)]] RWStructuredBuffer<uint> dGeometryToTrianglePowerOffset;
[[vk::binding(4, 0)]] RWStructuredBuffer<uint> emissiveTriangleCount;

struct PushConsts {
	uint instanceIndex;
	uint geometryIndex;
	uint triangleCount;
};
[[vk::push_constant]] PushConsts pushConsts;

[numthreads(32, 1, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
	const uint dstIndex = dispatchXYZ.x;
	const uint dstImageSize = textureDimensions(dstMip);

	if (any(dstIndex >= dstImageSize)) return;

	if (dstImageSize == 1) {
		const float newSum = srcMip[2 * dstIndex + 0] + srcMip[2 * dstIndex + 1];
		const float oldSum = dstMip[dstIndex];
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

	dstMip[dstIndex] = srcMip[2 * dstIndex + 0]
	                 + srcMip[2 * dstIndex + 1];
}