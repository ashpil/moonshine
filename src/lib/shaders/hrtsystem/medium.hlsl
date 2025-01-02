#pragma once

#include "ray.hlsl"
#include "spectrum.hlsl"

interface Medium {
    float transmittance(float distance);
    float pdf(float distance);
    float sample(float rand);
};

struct Homogeneous : Medium {
    float σ_s;
    float σ_a;

    static Homogeneous create(float σ_s, float σ_a) {
        Homogeneous h;
        h.σ_s = σ_s;
        h.σ_a = σ_a;
        return h;
    }

    static Homogeneous none() {
        return Homogeneous::create(0, 0);
    }

    float σ_t() {
        return σ_s + σ_a;
    }

    float transmittance(float distance) {
        if (σ_t() == 0) {
            // if distance == INF and σ_t() == 0 we want 1 as a result, not nan
            return 1;
        } else {
            return exp(-σ_t() * distance);
        }
    }

    float pdf(float distance) {
        return exp(-σ_t() * distance) * σ_t();
    }

    // TODO: doesn't sampling proportionally to σ_s (rather than σ_t) make more sense?
    // as the border case where σ_s == 0 should mean there is no scattering
    float sample(float rand) {
        return -log(1 - rand) / σ_t();
    }
};

struct RGBHomogeneous {
    float3 σ_s;
    float3 σ_a;

    Homogeneous sample(const float λ) {
        return Homogeneous::create(Spectrum::sampleReflectance(λ, σ_s), Spectrum::sampleReflectance(λ, σ_a));
    }
};
