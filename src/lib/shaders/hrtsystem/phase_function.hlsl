#pragma once

#include "../utils/mappings.hlsl"

struct PhaseFunctionEvaluation {
    float attenuation;
    float pdf;

    static PhaseFunctionEvaluation empty() {
        PhaseFunctionEvaluation eval;
        eval.attenuation = 0;
        eval.pdf = 0;
        return eval;
    }
};

struct PhaseFunctionSample {
    float3 dirWs;
    PhaseFunctionEvaluation eval;
};

interface PhaseFunction {
    PhaseFunctionEvaluation evaluate(float3 w_o, float3 w_i);
    PhaseFunctionSample sample(float3 w_o, float2 square);
};

struct Isotropic : PhaseFunction {
    PhaseFunctionEvaluation evaluate(float3 w_i, float3 w_o) {
        PhaseFunctionEvaluation eval;
        eval.attenuation = 1 / (4 * PI);
        eval.pdf = 1 / (4 * PI);
        return eval;
    }

    PhaseFunctionSample sample(float3 w_o, float2 square) {
        const float3 w_i = squareToUniformSphere(square);
        PhaseFunctionSample sample;
        sample.dirWs = w_i;
        sample.eval = evaluate(w_i, w_o);
        sample.eval.attenuation = sample.eval.attenuation / sample.eval.pdf;
        return sample;
    }
};