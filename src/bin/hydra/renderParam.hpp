#pragma once

#include <pxr/imaging/hd/renderDelegate.h>

#include "moonshine.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineRenderParam final : public HdRenderParam
{
public:
    HdMoonshineRenderParam(HdMoonshine* moonshine) : _moonshine(moonshine) {
        Extent2D extent = Extent2D {
            .width = 1,
            .height = 1,
        };

        uint8_t black[] = { 0, 0, 0, 255 };
        uint8_t grey[] = { 128, 128, 128, 255 };
        uint8_t white[] = { 255, 255, 255, 255 };

        _black3 = HdMoonshineCreateTexture(_moonshine, black, extent, TextureFormat::u8x4, "black3");
        _black1 = HdMoonshineCreateTexture(_moonshine, black, extent, TextureFormat::u8x1, "black1");
        _upNormal = HdMoonshineCreateTexture(_moonshine, grey, extent, TextureFormat::u8x2, "up normal");
        _grey3 = HdMoonshineCreateTexture(_moonshine, grey, extent, TextureFormat::u8x4, "grey3");
        _white1 = HdMoonshineCreateTexture(_moonshine, white, extent, TextureFormat::u8x1, "white1");
        _defaultMaterial = HdMoonshineCreateMaterial(_moonshine, Material {
            .normal = _upNormal,
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
    ImageHandle _upNormal;
    ImageHandle _grey3;
    ImageHandle _white1;
    MaterialHandle _defaultMaterial;
};

PXR_NAMESPACE_CLOSE_SCOPE