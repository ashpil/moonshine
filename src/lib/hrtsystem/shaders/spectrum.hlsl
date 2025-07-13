#pragma once

[[vk::binding(0, 2)]] SamplerState dSpectrumSampler;
[[vk::binding(1, 2)]] Texture1D<float> dSpectrumCIEX;
[[vk::binding(2, 2)]] Texture1D<float> dSpectrumCIEY;
[[vk::binding(3, 2)]] Texture1D<float> dSpectrumCIEZ;
[[vk::binding(4, 2)]] Texture1D<float> dSpectrumR;
[[vk::binding(5, 2)]] Texture1D<float> dSpectrumG;
[[vk::binding(6, 2)]] Texture1D<float> dSpectrumB;
[[vk::binding(7, 2)]] Texture1D<float> dSpectrumD65;

#include "../../shaders/utils/random.hlsl"
#include "../../shaders/utils/math.hlsl"
#include "../../shaders/utils/helpers.hlsl"

static const float CIE1931YIntegral = 106.85691710117189;

namespace Spectrum {
    float sampleTabulated(const float λ, const float start, const float end, Texture1D<float> texture) {
        // correctly handles LUT insetting: https://docs.vulkan.org/spec/latest/_images/vulkantexture0-ll.svg need samples to be on the dots
        const float size = end - start;
        const float spacing = size / textureDimensions(texture);
        const float t = (λ - start + (spacing / 2.0)) / (size + spacing);
        return texture.SampleLevel(dSpectrumSampler, t, 0);
    }

    float sampleReflectance(const float λ, const float3 reflectance) {
        const float samplesStart = 360;
        const float samplesEnd = 830;
        const float3 rgb = float3(
            sampleTabulated(λ, samplesStart, samplesEnd, dSpectrumR),
            sampleTabulated(λ, samplesStart, samplesEnd, dSpectrumG),
            sampleTabulated(λ, samplesStart, samplesEnd, dSpectrumB)
        );
        return dot(rgb, reflectance);
    }

    // a somewhat roundabout way of doing this but I believe it's correct
    float sampleEmission(const float λ, const float3 emission) {
        const float sampledReflectance = sampleReflectance(λ, emission);
        const float sampledD65 = sampleTabulated(λ, 300, 830, dSpectrumD65);
        return sampledReflectance * sampledD65;
    }

    float3 toXYZ(const float λ, const float s) {
        const float samplesStart = 360;
        const float samplesEnd = 830;
        const float3 rgb = float3(
            sampleTabulated(λ, samplesStart, samplesEnd, dSpectrumCIEX),
            sampleTabulated(λ, samplesStart, samplesEnd, dSpectrumCIEY),
            sampleTabulated(λ, samplesStart, samplesEnd, dSpectrumCIEZ)
        );
        return rgb * s / CIE1931YIntegral;
    }

    float3 toLinearSRGB(const float λ, const float s) {
        const float3 xyz = toXYZ(λ, s);
        const float3x3 XYZtoLinearSRGB = { 0.03276749869518854, -0.015543557073358668, -0.00504115364541362, -0.009800789737065342, 0.018969392573362078, 0.00042019608374440075, 0.0005626856849785213, -0.0020631808449212427, 0.010691028014591895 };
        return mul(XYZtoLinearSRGB, xyz);
    }
};

struct WavelengthSample {
    float λ;
    float pdf;

    static WavelengthSample sampleUniform(const float start, const float end, const float rand) {
        WavelengthSample s;
        s.λ = lerp(start, end, rand);
        s.pdf = 1 / (end - start);
        return s;
    }

    static WavelengthSample sampleVisible(const float rand) {
        WavelengthSample s;
        s.λ = 538 - 138.888889f * atanh(0.85691062f - 1.82750197f * rand);
        s.pdf = 0.0039398042f / pow(cosh(0.0072f * (s.λ - 538)), 2);
        return s;
    }
};
