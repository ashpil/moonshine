#include "../../lib/shaders/utils/helpers.hlsl"
#include "../../lib/shaders/utils/color.hlsl"

// all images should be same size
[[vk::binding(0, 0)]] Texture2D<float3> srcImage; // assumed to be linear, bt709 primaries
[[vk::binding(1, 0)]] Texture2D<float4> imguiPremultipliedAlphaImage; // imgui conventions with premultipled alpha
[[vk::image_format("unknown")]] [[vk::binding(2, 0)]] RWTexture2D<float4> dstImage;

struct PushConsts {
    float srcImageSceneReferredToDisplayReferredScale;
    float dstWhiteEncoding;
    Primaries dstPrimaries;
    TransferFunction dstTransferFunction;
};
[[vk::push_constant]] PushConsts pushConsts;

// returns linear color with BT709 primaries
float3 applyImgui(const float3 linearSRGBColor, const float4 imguiPremultipliedAlpha) {
    // imgui is not color aware at all. to match its default behavior, all blending with it must be done in nonlinear srgb
    const float3 nonlinearSrgbColor = SRGB::InvEOTF(saturate(linearSRGBColor));
    const float3 colorNonlinearSrgb = nonlinearSrgbColor * (1 - imguiPremultipliedAlpha.a) + imguiPremultipliedAlpha.rgb;
    return SRGB::EOTF(colorNonlinearSrgb);
}

[numthreads(8, 8, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
    const uint2 pixelIndex = dispatchXYZ.xy;
    const uint2 dstImageSize = textureDimensions(dstImage);

    if (any(pixelIndex >= dstImageSize)) return;

    const float3 srcColor = srcImage[pixelIndex] * pushConsts.srcImageSceneReferredToDisplayReferredScale;

    const float3 dstColor = applyImgui(srcColor, imguiPremultipliedAlphaImage[pixelIndex]);

    const float3 dstColorXYZ = mul(bt709Primaries.toXYZ(), dstColor);
    const float3 dstColorDstPrimaries = mul(pushConsts.dstPrimaries.fromXYZ(), dstColorXYZ);

    dstImage[pixelIndex] = float4(fromLinear(pushConsts.dstTransferFunction, dstColorDstPrimaries * pushConsts.dstWhiteEncoding), 1.0);
}
