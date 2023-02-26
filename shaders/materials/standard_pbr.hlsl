#include "material.hlsl"
#include "interface.hlsl"

[shader("callable")]
void sample(inout SampleParams params) {
    StandardPBR mat = StandardPBR::create(params.materialIndex, params.texcoords);

    MaterialSample sample = mat.sample(params.w_o, params.square);
    params.sample.pdf = sample.pdf;
    params.sample.w_i = sample.dirFs;
    params.sample.brdf = mat.eval(params.w_o, params.sample.w_i);
}

[shader("callable")]
void eval(inout EvalParams params) {
    StandardPBR mat = StandardPBR::create(params.materialIndex, params.texcoords);

    params.eval.pdf = mat.pdf(params.w_o, params.w_i);
    params.eval.brdf = mat.eval(params.w_o, params.w_i);
}
