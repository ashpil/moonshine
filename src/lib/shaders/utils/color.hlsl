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

