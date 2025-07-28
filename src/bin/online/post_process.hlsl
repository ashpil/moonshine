#include "../../lib/shaders/utils/helpers.hlsl"
#include "../../lib/shaders/utils/color.hlsl"

// all images should be same size
[[vk::binding(0, 0)]] Texture2D<float3> srcImage;
[[vk::binding(1, 0)]] Texture2D<float4> imguiPremultipliedAlphaImage; // imgui conventions with premultipled alpha
[[vk::image_format("unknown")]] [[vk::binding(2, 0)]] RWTexture2D<float4> dstImage;

struct PushConsts {
    float srcImageSceneReferredToDisplayReferredScale;
    row_major float3x3 srcPrimariesToXYZ;
    float dstWhiteEncoding;
    row_major float3x3 dstPrimariesFromXYZ;
    TransferFunction dstTransferFunction;
};
[[vk::push_constant]] PushConsts pushConsts;

float3 applyImgui(const float3 colorBT709, const float4 imguiPremultipliedAlpha) {
    if (imguiPremultipliedAlpha.a > 0.0) {
        // imgui is not color aware at all. to match its default behavior, all blending with it must be done with the srgb inv eotf applied
        const float3 srcNonlinearColor = SRGB::InvEOTF(colorBT709); // TODO: could do some sort of smarter gamut clipping
        const float3 dstNonlinearColor = srcNonlinearColor * (1 - imguiPremultipliedAlpha.a) + imguiPremultipliedAlpha.rgb;
        return SRGB::EOTF(dstNonlinearColor);
    } else {
        // keeping this separate so our EOTF does not clamp colors outside of gui. will lead to strange behavior
        // for real alpha fades, but we don't use that.
        return colorBT709;
    }
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
    const uint2 pixelIndex = dispatchXYZ.xy;
    const uint2 dstImageSize = textureDimensions(dstImage);

    if (any(pixelIndex >= dstImageSize)) return;

    const float3 srcColor = srcImage[pixelIndex] * pushConsts.srcImageSceneReferredToDisplayReferredScale;
    const float3 srcColorXYZ = mul(pushConsts.srcPrimariesToXYZ, srcColor);

    const float3 dstColorBT709 = applyImgui(mul(bt709Primaries.fromXYZ(), srcColorXYZ), imguiPremultipliedAlphaImage[pixelIndex]);

    const float3 dstColorXYZ = mul(bt709Primaries.toXYZ(), dstColorBT709);
    const float3 dstColorDstPrimaries = mul(pushConsts.dstPrimariesFromXYZ, dstColorXYZ);

    dstImage[pixelIndex] = float4(fromLinear(pushConsts.dstTransferFunction, dstColorDstPrimaries * pushConsts.dstWhiteEncoding), 1.0);
}
