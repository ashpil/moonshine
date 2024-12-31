#pragma once

#include "../utils/mappings.hlsl"
#include "material.hlsl"

struct Isotropic : BSDF {
    BSDFEvaluation evaluate(float3 w_i, float3 w_o) {
        BSDFEvaluation eval;
        eval.attenuation = 1 / (4 * PI);
        eval.pdf = 1 / (4 * PI);
        return eval;
    }

    BSDFSample sample(float3 w_o, float2 square) {
        const float3 w_i = squareToUniformSphere(square);
        BSDFSample sample;
        sample.dir = w_i;
        sample.eval = evaluate(w_i, w_o);
        sample.eval.attenuation = sample.eval.attenuation / sample.eval.pdf;
        return sample;
    }
};