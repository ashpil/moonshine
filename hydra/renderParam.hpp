#pragma once

#include "moonshine.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineRenderParam final : public HdRenderParam
{
public:
    HdMoonshineRenderParam(HdMoonshine* moonshine) : _moonshine(moonshine) {
        const ImageHandle emissive = HdMoonshineCreateSolidTexture3(_moonshine, F32x3 { .x = 0.0f, .y = 0.0f, .z = 0.0f }, "emissive");
        const ImageHandle normal = HdMoonshineCreateSolidTexture2(_moonshine, F32x2 { .x = 0.5f, .y = 0.5f }, "normal");
        const ImageHandle color = HdMoonshineCreateSolidTexture3(_moonshine, F32x3 { .x = 0.5f, .y = 0.5f, .z = 0.5f }, "color");
        _material = HdMoonshineCreateMaterialLambert(_moonshine, normal, emissive, color);
    }

    HdMoonshine* _moonshine;

    MaterialHandle _material; // keep this here while only one type of material is supported
};

PXR_NAMESPACE_CLOSE_SCOPE