#include "../utils/helpers.hlsl"
#include "../utils/mappings.hlsl"

[[vk::combinedImageSampler]] [[vk::binding(0, 0)]] Texture2D<float3> srcTexture;
[[vk::combinedImageSampler]] [[vk::binding(0, 0)]] SamplerState srcTextureSampler;

[[vk::binding(1, 0)]] RWTexture2D<float4> dstImage;

[numthreads(8, 8, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
	const uint2 pixelIndex = dispatchXYZ.xy;
	const uint2 dstImageSize = textureDimensions(dstImage);

	if (any(pixelIndex >= dstImageSize)) return;

	float3 color = float3(0.0, 0.0, 0.0);
	const uint samples_per_dim = 3;
	for (uint i = 0; i < samples_per_dim; i++) {
		for (uint j = 0; j < samples_per_dim; j++) {
			const float2 subpixel = float2(1 + i, 1 + j) / float2(samples_per_dim + 1, samples_per_dim + 1);
			const float2 dstCoords = (float2(pixelIndex) + subpixel) / float2(dstImageSize);
			const float3 dir = squareToEqualAreaSphere(dstCoords);
			const float2 srcCoords = cartesianToSpherical(dir) / float2(2 * PI, PI);
			color += srcTexture.SampleLevel(srcTextureSampler, srcCoords, 0); // could also technically compute some sort of gradient and get area subtended by this pixel
		}
	}

	const uint total_samples = samples_per_dim * samples_per_dim;
	dstImage[pixelIndex] = float4(color / float(total_samples), 1);
}