#pragma once

#include <pxr/imaging/hd/renderDelegate.h>

#include "moonshine.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineRenderParam final : public HdRenderParam
{
public:
    HdMoonshineRenderParam(HdMoonshine* moonshine) : _moonshine(moonshine) {
        _black3 = HdMoonshineCreateSolidTexture3(_moonshine, F32x3 { .x = 0.0f, .y = 0.0f, .z = 0.0f }, "black3");
        _black1 = HdMoonshineCreateSolidTexture1(_moonshine, 0.0, "black1");
        _up = HdMoonshineCreateSolidTexture3(_moonshine, F32x3 { .x = 0.0f, .y = 0.0f, .z = 1.0f }, "up");
        _grey3 = HdMoonshineCreateSolidTexture3(_moonshine, F32x3 { .x = 0.5f, .y = 0.5f, .z = 0.5f }, "grey3");
        _white1 = HdMoonshineCreateSolidTexture1(_moonshine, 1.0, "white1");
        _defaultMaterial = HdMoonshineCreateMaterial(_moonshine, Material {
            .normal = _up,
            .emissive = _black3,
            .color = _grey3,
            .metalness = _black1,
            .roughness = _white1,
            .ior = 1.5,
        });
    }

    HdMoonshine* _moonshine;

    // some defaults
    ImageHandle _black3;
    ImageHandle _black1;
    ImageHandle _up;
    ImageHandle _grey3;
    ImageHandle _white1;
    MaterialHandle _defaultMaterial;
};

PXR_NAMESPACE_CLOSE_SCOPE