#pragma once

#include "../utils/mappings.hlsl"
#include "bsdf.hlsl"

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

struct HenyeyGreenstein : BSDF {
    float g;

    static HenyeyGreenstein create(const float g) {
        HenyeyGreenstein phase;
        phase.g = g;
        return phase;
    }

    static float HG(const float g, const float cosTheta) {
        const float denom = 1 + g * g + 2 * g * cosTheta;
        return (1 - g * g) / (denom * sqrt(denom) * 4 * PI);
    }

    BSDFEvaluation evaluate(float3 w_i, float3 w_o) {
        BSDFEvaluation eval;
        eval.attenuation = HG(g, dot(w_i, w_o));
        eval.pdf = HG(g, dot(w_i, w_o));
        return eval;
    }

    BSDFSample sample(float3 w_o, float2 square) {
        // TODO: is there a sampling formulation here that doesn't need to special case zero?
        float cosTheta;
        if (abs(g) < 1e-3f) {
            cosTheta = 1 - 2 * square.x;
        } else {
            cosTheta = -1 / (2 * g) * (1 + g * g - (1 - g * g) * (1 - g * g) / (1 + g - 2 * g * square.x));
        }
        const float sinTheta = sqrt(1 - cosTheta * cosTheta);
        const float phi = 2 * PI * square.y;
        const float3 w_i = Frame::create(w_o).frameToWorld(sphericalToCartesian(sinTheta, cosTheta, phi));
        BSDFSample sample;
        sample.dir = w_i;
        sample.eval.pdf = HG(g, cosTheta);
        sample.eval.attenuation = 1;
        return sample;
    }
};