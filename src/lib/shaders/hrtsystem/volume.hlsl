#pragma once

#include "medium.hlsl"

struct CauchyIOR {
    float a;
    float b;

    float at(const float λ) {
        return a + b / (λ * λ);
    }
};

struct Volume {
    Homogeneous medium;
    float IOR;

    static Volume create(Homogeneous medium, float IOR) {
        Volume v;
        v.medium = medium;
        v.IOR = IOR;
        return v;
    }

    static Volume transparent(float IOR) {
        return Volume::create(Homogeneous::none(), IOR);
    }
};

struct ChromaticVolume {
    ChromaticHomogeneous medium;
    CauchyIOR IOR;

    Volume at(const float λ) {
        return Volume::create(medium.at(λ), IOR.at(λ));
    }
};
