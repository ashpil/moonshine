#pragma once

#include <cstdint>
#include <stdint.h>
#include <stddef.h>

typedef uint32_t MeshHandle;
typedef uint32_t ImageHandle;
typedef uint32_t MaterialHandle;

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

typedef struct HdMoonshine HdMoonshine;
extern "C" HdMoonshine* HdMoonshineCreate(void);
extern "C" void HdMoonshineDestroy(HdMoonshine*);
extern "C" bool HdMoonshineRender(HdMoonshine*, float*);
extern "C" MeshHandle HdMoonshineCreateMesh(HdMoonshine*, const F32x3*, const F32x3*, const F32x2*, size_t, const U32x3*, size_t);
extern "C" ImageHandle HdMoonshineCreateSolidTexture1(HdMoonshine*, float, const char*);
extern "C" ImageHandle HdMoonshineCreateSolidTexture2(HdMoonshine*, F32x2, const char*);
extern "C" ImageHandle HdMoonshineCreateSolidTexture3(HdMoonshine*, F32x3, const char*);
extern "C" MaterialHandle HdMoonshineCreateMaterialLambert(HdMoonshine*, ImageHandle, ImageHandle, ImageHandle);
extern "C" bool HdMoonshineCreateInstance(HdMoonshine*, Mat3x4, const Geometry*, size_t);
