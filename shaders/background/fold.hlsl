#include "../utils/helpers.hlsl"

[[vk::binding(0, 0)]] Texture2D<float> srcMip;
[[vk::binding(1, 0)]] RWTexture2D<float> dstMip;

[numthreads(8, 8, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
	const uint2 pixelIndex = dispatchXYZ.xy;
	const uint2 dstImageSize = textureDimensions(dstMip);

	if (any(pixelIndex >= dstImageSize)) return;

	dstMip[pixelIndex] = srcMip[2 * pixelIndex + uint2(0, 0)]
	                   + srcMip[2 * pixelIndex + uint2(1, 0)]
	                   + srcMip[2 * pixelIndex + uint2(0, 1)]
	                   + srcMip[2 * pixelIndex + uint2(1, 1)];
}