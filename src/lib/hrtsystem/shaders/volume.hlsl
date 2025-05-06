#pragma once

#include "medium.hlsl"
#include "bsdf.hlsl"
#include "phase_function.hlsl"

struct Volume {
    Homogeneous medium;
    HenyeyGreenstein phase;
    float IOR;

    static Volume create(Homogeneous medium, HenyeyGreenstein phase, float IOR) {
        Volume v;
        v.medium = medium;
        v.phase = phase;
        v.IOR = IOR;
        return v;
    }

    static Volume transparent(float IOR) {
        return Volume::create(Homogeneous::none(), HenyeyGreenstein::create(0), IOR);
    }
};

struct ChromaticVolume {
    ChromaticHomogeneous medium;
    HenyeyGreenstein phase;
    CauchyIOR IOR;

    Volume at(const float λ) {
        return Volume::create(medium.at(λ), phase, IOR.at(λ));
    }
};
