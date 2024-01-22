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

struct Geometry {
    uint meshIdx;
    uint materialIdx;
    bool sampled;
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

[[vk::binding(0, 0)]] Texture2D dTextures[];
[[vk::binding(0, 1)]] RaytracingAccelerationStructure dTLAS;
[[vk::binding(1, 1)]] StructuredBuffer<Instance> dInstances;
[[vk::binding(2, 1)]] StructuredBuffer<row_major float3x4> dWorldToInstance;

struct LightAliasData {
    uint instanceIndex;
    uint geometryIndex;
    uint primitiveIndex;
};

template <class Data>
struct AliasEntry {
    uint alias;
    float select;
    Data data;
};

[[vk::binding(3, 1)]] StructuredBuffer<AliasEntry<LightAliasData> > dEmitterAliasTable;

[[vk::binding(4, 1)]] StructuredBuffer<Mesh> dMeshes;
[[vk::binding(5, 1)]] StructuredBuffer<Geometry> dGeometries;

// MATERIALS
enum class MaterialType : uint {
    Glass,
    Lambert,
    PerfectMirror,
    StandardPBR,
};

struct MaterialVariantData {
    // all materials have these two
    uint normal;
    uint emissive;

    // then material specific stuff
    // find appropriate thing to decode from address using `type`
    MaterialType type;
    uint64_t materialAddress;
};

[[vk::binding(6, 1)]] SamplerState dTextureSampler;
[[vk::binding(7, 1)]] StructuredBuffer<MaterialVariantData> dMaterials;

// BACKGROUND
[[vk::binding(0, 2)]] StructuredBuffer<AliasEntry<float> > dBackgroundMarginalAlias; // size: backgroundTexture.height
[[vk::binding(1, 2)]] StructuredBuffer<AliasEntry<float> > dBackgroundConditionalAlias; // size: backgroundTexture.height * backgroundTexture.width

// OUTPUT
[[vk::binding(0, 3)]] RWTexture2D<float4> dOutputImage;

// PUSH CONSTANTS
#include "camera.hlsl" // hmmmmmm
struct PushConsts {
	Camera camera;
	uint sampleCount;
    uint backgroundTexture;
};
[[vk::push_constant]] PushConsts pushConsts;

// SPECIALIZATION CONSTANTS
[[vk::constant_id(0)]] const uint SAMPLES_PER_RUN = 1;
[[vk::constant_id(1)]] const uint MAX_BOUNCES = 4;
[[vk::constant_id(2)]] const uint ENV_SAMPLES_PER_BOUNCE = 1;     // how many times the environment map should be sampled per bounce for light
[[vk::constant_id(3)]] const uint MESH_SAMPLES_PER_BOUNCE = 1;    // how many times emissive meshes should be sampled per bounce for light

