#pragma once

#include "math.hlsl"

namespace srgb {
    template<typename T>
    T EOTF(T value) {
        return select(value <= 0.04045, value / 12.92, pow((value + 0.055) / 1.055, 2.4));
    }

    template<typename T>
    T InvEOTF(T value) {
        return select(value <= 0.0031308, value * 12.92, 1.055 * pow(value, 1.0 / 2.4) - 0.055);
    }
};

float3 XYZToxyY(float3 XYZ) {
    return float3(
        XYZ[0] / normL1(XYZ),
        XYZ[1] / normL1(XYZ),
        XYZ[1]
    );
}

float3 xyYToXYZ(float3 xyY) {
    return float3(
        xyY[0] * xyY[2] / xyY[1],
        xyY[2],
        (1 - xyY[0] - xyY[1]) * xyY[2] / xyY[1]
    );
}

struct Primaries {
    float2 red;
    float2 green;
    float2 blue;
    float2 white;

    float3x3 toXYZ() {
        const float3x3 primaryConversion = transpose(float3x3(
            xyYToXYZ(float3(red, 1)),
            xyYToXYZ(float3(green, 1)),
            xyYToXYZ(float3(blue, 1))
        ));

        const float3 XYZWhiteInRGB = mul(mat3Inverse(primaryConversion), xyYToXYZ(float3(white, 1)));

        const float3x3 whiteConversion = float3x3(
            XYZWhiteInRGB[0], 0, 0,
            0, XYZWhiteInRGB[1], 0,
            0, 0, XYZWhiteInRGB[2]
        );

        return mul(primaryConversion, whiteConversion);
    }

    float3x3 fromXYZ() {
        return mat3Inverse(toXYZ());
    }
};

static const Primaries srgbPrimaries = {
    float2(0.64, 0.33),
    float2(0.3, 0.6),
    float2(0.15, 0.06),
    float2(0.3127, 0.3290),
};

enum class TransferFunction: uint {
    BT1886,
    Gamma22,
    Gamma28,
    ST240,
    ExtLinear,
    Log100,
    Log316,
    XVYCC,
    SRGB,
    ExtSrgb,
    ST2084PQ,
    ST428,
    HLG,
};

template<typename T>
T toLinear(TransferFunction tf, T value) {
    switch (tf) {
        case TransferFunction::SRGB: {
            return srgb::EOTF(value);
        }
        case TransferFunction::ExtLinear: {
            return value;
        }
        default: {
            return 0.0 / 0.0; // TODO
        }
    }
}

template<typename T>
T fromLinear(TransferFunction tf, T value) {
    switch (tf) {
        case TransferFunction::SRGB: {
            return srgb::InvEOTF(value);
        }
        case TransferFunction::ExtLinear: {
            return value;
        }
        default: {
            return 0.0 / 0.0; // TODO
        }
    }
}
