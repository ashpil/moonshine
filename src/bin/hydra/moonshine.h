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
typedef uint32_t CameraHandle;
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

typedef struct Mat4x3 {
    F32x4 x, y, z;
} Mat4x3;

typedef struct Extent2D {
    uint32_t width;
    uint32_t height;
} Extent2D;

typedef struct ThinLens {
    float vfov;
    float aperture;
    float focus_distance;
} ThinLens;

typedef struct Material {
    ImageHandle normal;
    ImageHandle emissive;
    ImageHandle color;
    ImageHandle metalness;
    ImageHandle roughness;
    float ior;
} Material;

typedef enum TextureFormat {
    f32x1,
    f32x2,
    f32x4,
    f16x4,
    u8x1,
    u8x2,
    u8x4,
    u8x4_srgb,
} TextureFormat;

typedef struct HdMoonshine HdMoonshine;
extern "C" HdMoonshine* HdMoonshineCreate(void);
extern "C" void HdMoonshineDestroy(HdMoonshine*);
extern "C" bool HdMoonshineRender(HdMoonshine*, SensorHandle, CameraHandle);
extern "C" bool HdMoonshineRebuildPipeline(HdMoonshine*);
extern "C" MeshHandle HdMoonshineCreateMesh(HdMoonshine*, const F32x3*, const F32x3*, const F32x2*, size_t);
extern "C" ImageHandle HdMoonshineCreateTexture(HdMoonshine*, uint8_t*, Extent2D, TextureFormat, const char*);
extern "C" MaterialHandle HdMoonshineCreateMaterial(HdMoonshine*, Material);
extern "C" void HdMoonshineSetMaterialNormal(HdMoonshine*, MaterialHandle, ImageHandle);
extern "C" void HdMoonshineSetMaterialEmissive(HdMoonshine*, MaterialHandle, ImageHandle);
extern "C" void HdMoonshineSetMaterialColor(HdMoonshine*, MaterialHandle, ImageHandle);
extern "C" void HdMoonshineSetMaterialMetalness(HdMoonshine*, MaterialHandle, ImageHandle);
extern "C" void HdMoonshineSetMaterialRoughness(HdMoonshine*, MaterialHandle, ImageHandle);
extern "C" void HdMoonshineSetMaterialIOR(HdMoonshine*, MaterialHandle, float);
extern "C" InstanceHandle HdMoonshineCreateInstance(HdMoonshine*, Mat4x3, MeshHandle, MaterialHandle, bool);
extern "C" void HdMoonshineDestroyInstance(HdMoonshine*, InstanceHandle);
extern "C" void HdMoonshineSetInstance(HdMoonshine*, InstanceHandle, Mat4x3, bool);
extern "C" SensorHandle HdMoonshineCreateSensor(HdMoonshine*, Extent2D);
extern "C" float* HdMoonshineGetSensorData(const HdMoonshine*, SensorHandle);
extern "C" void HdMoonshineClearSensor(HdMoonshine*, SensorHandle);
extern "C" uint32_t HdMoonshineGetSensorSampleCount(const HdMoonshine*, SensorHandle);
extern "C" CameraHandle HdMoonshineCreateCamera(HdMoonshine*, ThinLens, Mat4x3, const char*);
extern "C" void HdMoonshineSetCamera(HdMoonshine*, CameraHandle, ThinLens, Mat4x3);
