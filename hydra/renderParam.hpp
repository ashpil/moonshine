#pragma once

#include <pxr/imaging/hd/renderDelegate.h>

#include "moonshine.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineRenderParam final : public HdRenderParam
{
public:
    HdMoonshineRenderParam(HdMoonshine* moonshine) : _moonshine(moonshine) {
        _defaultEmissive = HdMoonshineCreateSolidTexture3(_moonshine, F32x3 { .x = 0.0f, .y = 0.0f, .z = 0.0f }, "emissive");
        _defaultNormal = HdMoonshineCreateSolidTexture2(_moonshine, F32x2 { .x = 0.5f, .y = 0.5f }, "normal");
        _defaultColor = HdMoonshineCreateSolidTexture3(_moonshine, F32x3 { .x = 0.5f, .y = 0.5f, .z = 0.5f }, "color");
        _defaultMaterial = HdMoonshineCreateMaterialLambert(_moonshine, _defaultNormal, _defaultEmissive, _defaultColor);
    }

    HdMoonshine* _moonshine;

    // some defaults
    ImageHandle _defaultEmissive;
    ImageHandle _defaultNormal;
    ImageHandle _defaultColor;
    MaterialHandle _defaultMaterial;
};

PXR_NAMESPACE_CLOSE_SCOPE