// sort of viewing this whole file as a temporary hack
// until emit-h is resurrected

#pragma once

#include <cstdint>
#include <stdint.h>
#include <stddef.h>

typedef uint32_t MeshHandle;
typedef uint32_t ImageHandle;
typedef uint32_t MaterialHandle;
typedef uint32_t SensorHandle;
typedef uint32_t LensHandle;
typedef uint32_t InstanceHandle;

typedef struct F32x2 {
    float x, y;
} F32x2;

typedef struct F32x3 {
    float x, y, z;
} F32x3;

typedef struct F32x4 {
    float x, y, z, w;
} F32x4;

typedef struct U32x3 {
    uint32_t x, y, z;
} U32x3;

typedef struct Mat3x4 {
    F32x4 x, y, z;
} Mat3x4;

typedef struct Geometry {
    MeshHandle mesh;
    MaterialHandle material;
    bool sampled;
} Geometry;

typedef struct Extent2D {
    uint32_t width;
    uint32_t height;
} Extent2D;

typedef struct Lens {
    F32x3 origin;
    F32x3 forward;
    F32x3 up;
    float vfov;
    float aperture;
    float focus_distance;
} Lens;

typedef struct Material {
    ImageHandle normal;
    ImageHandle emissive;
    ImageHandle color;
    ImageHandle metalness;
    ImageHandle roughness;
    float ior;
} Material;

typedef struct HdMoonshine HdMoonshine;
extern "C" HdMoonshine* HdMoonshineCreate(void);
extern "C" void HdMoonshineDestroy(HdMoonshine*);
extern "C" bool HdMoonshineRender(HdMoonshine*, SensorHandle, LensHandle);
extern "C" MeshHandle HdMoonshineCreateMesh(HdMoonshine*, const F32x3*, const F32x3*, const F32x2*, size_t, const U32x3*, size_t);
extern "C" ImageHandle HdMoonshineCreateSolidTexture1(HdMoonshine*, float, const char*);
extern "C" ImageHandle HdMoonshineCreateSolidTexture2(HdMoonshine*, F32x2, const char*);
extern "C" ImageHandle HdMoonshineCreateSolidTexture3(HdMoonshine*, F32x3, const char*);
extern "C" MaterialHandle HdMoonshineCreateMaterial(HdMoonshine*, Material);
extern "C" void HdMoonshineSetMaterialNormal(HdMoonshine*, MaterialHandle, ImageHandle);
extern "C" void HdMoonshineSetMaterialEmissive(HdMoonshine*, MaterialHandle, ImageHandle);
extern "C" void HdMoonshineSetMaterialColor(HdMoonshine*, MaterialHandle, ImageHandle);
extern "C" void HdMoonshineSetMaterialMetalness(HdMoonshine*, MaterialHandle, ImageHandle);
extern "C" void HdMoonshineSetMaterialRoughness(HdMoonshine*, MaterialHandle, ImageHandle);
extern "C" void HdMoonshineSetMaterialIOR(HdMoonshine*, MaterialHandle, float);
extern "C" InstanceHandle HdMoonshineCreateInstance(HdMoonshine*, Mat3x4, const Geometry*, size_t, bool);
extern "C" void HdMoonshineDestroyInstance(HdMoonshine*, InstanceHandle);
extern "C" void HdMoonshineSetInstanceTransform(HdMoonshine*, InstanceHandle, Mat3x4);
extern "C" void HdMoonshineSetInstanceVisibility(HdMoonshine*, InstanceHandle, bool);
extern "C" SensorHandle HdMoonshineCreateSensor(HdMoonshine*, Extent2D);
extern "C" float* HdMoonshineGetSensorData(const HdMoonshine*, SensorHandle);
extern "C" LensHandle HdMoonshineCreateLens(HdMoonshine*, Lens);
extern "C" void HdMoonshineSetLens(HdMoonshine*, LensHandle, Lens);
