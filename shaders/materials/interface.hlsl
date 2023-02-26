
struct MaterialSample2 {
    float3 w_i;
    float pdf;
    float3 brdf;
};

struct SampleParams {
    // material info
    uint materialIndex;
    float2 texcoords;

    // in
    float3 w_o; // out direction
    float2 square; // rng input

    // out
    MaterialSample2 sample;
};

MaterialSample2 sampleMaterial(uint materialIndex, float2 texcoords, float3 w_o, float2 square) {
    SampleParams params;
    params.materialIndex = materialIndex;
    params.texcoords = texcoords;

    params.w_o = w_o;
    params.square = square;

    CallShader(0, params);

    return params.sample;
}

struct MaterialEval {
    float pdf;
    float3 brdf;
};

struct EvalParams {
    // material info
    uint materialIndex;
    float2 texcoords;

    // in
    float3 w_o;
    float3 w_i;

    // out
    MaterialEval eval;
};

MaterialEval evalMaterial(uint materialIndex, float2 texcoords, float3 w_o, float3 w_i) {
    EvalParams params;
    params.materialIndex = materialIndex;
    params.texcoords = texcoords;

    params.w_o = w_o;
    params.w_i = w_i;

    CallShader(1, params);

    return params.eval;
}
