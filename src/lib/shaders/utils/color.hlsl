#pragma once

#include "math.hlsl"

namespace SRGB {
    template<typename T>
    T EOTF(T value) {
        return select(value <= 0.04045, value / 12.92, pow((value + 0.055) / 1.055, 2.4));
    }

    template<typename T>
    T InvEOTF(T value) {
        return select(value <= 0.0031308, value * 12.92, 1.055 * pow(value, 1.0 / 2.4) - 0.055);
    }
};

namespace ST2084PQ {
    static float m_1 = 2610.0 / 16384.0;
    static float m_2 = (2523.0 / 4096.0) * 128.0;

    static float c_1 = 3424 / 4096.0;
    static float c_2 = (2413 / 4096.0) * 32.0;
    static float c_3 = (2392 / 4096.0) * 32.0;

    template<typename T>
    T EOTF(T value) {
        const T Y = pow(max((pow(value, 1.0 / m_2) - c_1), 0) / (c_2 - c_3 * pow(value, 1.0 / m_2)), 1.0 / m_1);
        return 10000 * Y;
    }

    template<typename T>
    T InvEOTF(T value) {
        const T Y = value / 10000;
        return pow((c_1 + c_2 * pow(Y, m_1)) / (1 + c_3 * pow(Y, m_1)), m_2);
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

static const Primaries bt709Primaries = {
    float2(0.64, 0.33),
    float2(0.3, 0.6),
    float2(0.15, 0.06),
    float2(0.3127, 0.3290),
};

enum class TransferFunction: uint {
    Linear,
    ExtendedLinear,
    SRGB,
    ST2084PQ,
};

template<typename T>
T toLinear(TransferFunction tf, T value) {
    switch (tf) {
        case TransferFunction::Linear: {
            return saturate(value);
        }
        case TransferFunction::ExtendedLinear: {
            return value;
        }
        case TransferFunction::SRGB: {
            return SRGB::EOTF(value);
        }
        case TransferFunction::ST2084PQ: {
            return ST2084PQ::EOTF(value);
        }
    }
}

template<typename T>
T fromLinear(TransferFunction tf, T value) {
    switch (tf) {
        case TransferFunction::Linear: {
            return saturate(value);
        }
        case TransferFunction::ExtendedLinear: {
            return value;
        }
        case TransferFunction::SRGB: {
            return SRGB::InvEOTF(value);
        }
        case TransferFunction::ST2084PQ: {
            return ST2084PQ::InvEOTF(value);
        }
    }
}
