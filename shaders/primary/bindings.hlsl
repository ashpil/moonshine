// set 0 - scene
// set 1 - background
// set 2 - output

// I use the `d` prefix to indicate a global variable
// because as a functional programmer impure functions scare me

// GEOMETRY
struct Mesh {
    uint64_t positionAddress;
    uint64_t texcoordAddress; // may be zero, for no texcoords
    uint64_t normalAddress; // may be zero, for no vertex normals

    uint64_t indexAddress;
};

struct Instance { // same required by vulkan on host side
    row_major float3x4 transform;
    uint instanceCustomIndexAndMask;
    uint instanceShaderBindingTableRecordOffsetAndFlags;
    uint64_t accelerationStructureReference;

    uint instanceID() {
        return instanceCustomIndexAndMask & 0x00FFFFFF;
    }
};

[[vk::binding(0, 0)]] RaytracingAccelerationStructure dTLAS;
[[vk::binding(1, 0)]] StructuredBuffer<Instance> dInstances;
[[vk::binding(2, 0)]] StructuredBuffer<row_major float3x4> dWorldToInstance;

struct AliasEntry {
    uint alias;
    float weight;
    uint instanceIndex;
    uint geometryIndex;
    uint primitiveIndex;
};

[[vk::binding(3, 0)]] StructuredBuffer<AliasEntry> dEmitterAliasTable;

[[vk::binding(4, 0)]] StructuredBuffer<Mesh> dMeshes;
[[vk::binding(5, 0)]] StructuredBuffer<uint> dMeshIdxs;
[[vk::binding(6, 0)]] StructuredBuffer<uint> dMaterialIdxs;

// MATERIALS
// `values` is what I call non-texture material properties
struct Values {
    float ior;
};

[[vk::binding(7, 0)]] SamplerState dTextureSampler;
[[vk::binding(8, 0)]] Texture2D dMaterialTextures[];
[[vk::binding(9, 0)]] StructuredBuffer<Values> dMaterialValues;

// BACKGROUND
[[vk::binding(0, 1)]] Texture2D<float3> dBackgroundTexture;
[[vk::binding(0, 1)]] SamplerState dBackgroundSampler;

[[vk::binding(1, 1)]] RWTexture2D<float> dConditionalPdfsIntegrals;
[[vk::binding(2, 1)]] RWTexture2D<float> dConditionalCdfs;

[[vk::binding(3, 1)]] RWTexture1D<float> dMarginalPdfIntegral;
[[vk::binding(4, 1)]] RWTexture1D<float> dMarginalCdf;

// OUTPUT
[[vk::binding(0, 2)]] RWTexture2D<float4> dOutputImage;
[[vk::binding(1, 2)]] RWTexture2D<float4> dAccumulationImage;

// PUSH CONSTANTS
#include "camera.hlsl" // hmmmmmm
struct PushConsts {
	Camera camera;
	uint sampleCount;
};
[[vk::push_constant]] PushConsts pushConsts;

// SPECIALIZATION CONSTANTS
[[vk::constant_id(0)]] const uint SAMPLES_PER_RUN = 1;
[[vk::constant_id(1)]] const uint MAX_BOUNCES = 4;
[[vk::constant_id(2)]] const uint ENV_SAMPLES_PER_BOUNCE = 1;     // how many times the environment map should be sampled per bounce for light
[[vk::constant_id(3)]] const uint MESH_SAMPLES_PER_BOUNCE = 1;    // how many times emissive meshes should be sampled per bounce for light

