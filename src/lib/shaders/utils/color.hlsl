#pragma once

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

struct Primaries {
    float2 red;
    float2 blue;
    float2 green;
    float2 white;
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
