float3 decodeNormal(float2 rg) {
    rg = rg * 2 - 1;
    return float3(rg, sqrt(1.0 - saturate(dot(rg, rg)))); // saturate due to float/compression annoyingness
}

Frame lookupTextureNormal(uint textureIndex, float2 texcoords, Frame tangentFrame) {
    float3 tmp = tangentFrame.n;
    tangentFrame.n = tangentFrame.t;
    tangentFrame.t = tmp;

    float3 normalTangentSpace = decodeNormal(dMaterialTextures[NonUniformResourceIndex(textureIndex)].SampleLevel(dTextureSampler, texcoords, 0).rg);

    Frame textureFrame = tangentFrame;
    textureFrame.n = normalize(tangentFrame.frameToWorld(normalTangentSpace).xyz);
    textureFrame.reorthogonalize();

    return textureFrame;
}

// sort of a weird system rn
// represents all parameters a material might have
// then, to get a specific interpretation of these parameters,
// just call getX where X is the specific material model
//
// the purpose of this is to be able to easily swap material models when testing
// as well as somewhere to store material parameters that aren't really reliant on a specific material model,
// such as the normal or emissive map
struct MaterialParameters {
    float ior;
    float3 color;
    float metalness;
    float roughness;

    float3 emissive;

    Frame frame;

    static MaterialParameters create(uint materialIndex, float2 texcoords, Frame tangentFrame) {
        MaterialInput input = dMaterials[NonUniformResourceIndex(materialIndex)];

        MaterialParameters params;
        params.ior = input.ior;
        params.color = dMaterialTextures[NonUniformResourceIndex(input.color)].SampleLevel(dTextureSampler, texcoords, 0).rgb;
        params.emissive = dMaterialTextures[NonUniformResourceIndex(input.emissive)].SampleLevel(dTextureSampler, texcoords, 0).rgb;
        params.metalness = dMaterialTextures[NonUniformResourceIndex(input.metalness)].SampleLevel(dTextureSampler, texcoords, 0).r;
        params.roughness = dMaterialTextures[NonUniformResourceIndex(input.roughness)].SampleLevel(dTextureSampler, texcoords, 0).r;
        params.frame = lookupTextureNormal(input.normal, texcoords, tangentFrame);
        return params;
    }
};
