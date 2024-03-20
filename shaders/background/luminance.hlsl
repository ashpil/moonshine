#include "../utils/math.hlsl"
#include "../utils/helpers.hlsl"

[[vk::binding(0, 0)]] Texture2D<float3> srcColorImage;
[[vk::binding(1, 0)]] RWTexture2D<float> dstLuminanceImage;

[numthreads(8, 8, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
	const uint2 pixelIndex = dispatchXYZ.xy;
	const uint2 dstImageSize = textureDimensions(dstLuminanceImage);

	if (any(pixelIndex >= dstImageSize)) return;

	dstLuminanceImage[pixelIndex] = luminance(srcColorImage[pixelIndex]);
}