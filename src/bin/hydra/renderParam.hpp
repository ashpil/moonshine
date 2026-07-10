#pragma once

#include <pxr/imaging/hd/renderDelegate.h>

#include "moonshine.h"

#include <cmath>

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

        // unit quad centered at origin in the XY plane, facing -Z
        const F32x3 quadPositions[] = {
            { -0.5, -0.5, 0 }, { -0.5, 0.5, 0 }, { 0.5, -0.5, 0 },
            { -0.5,  0.5, 0 }, {  0.5, 0.5, 0 }, { 0.5, -0.5, 0 },
        };
        const F32x3 quadNormals[] = {
            { 0, 0, -1 }, { 0, 0, -1 }, { 0, 0, -1 },
            { 0, 0, -1 }, { 0, 0, -1 }, { 0, 0, -1 },
        };
        _unitQuad = HdMoonshineCreateMesh(_moonshine, quadPositions, quadNormals, nullptr, 6);

        // unit-radius disk centered at origin in the XY plane, facing -Z
        constexpr uint32_t diskSegments = 32;
        F32x3 diskPositions[diskSegments * 3];
        F32x3 diskNormals[diskSegments * 3];
        const auto rim = [](uint32_t vertex) {
            const float theta = 2.0f * (float)M_PI * (vertex % diskSegments) / diskSegments;
            return F32x3 { std::cos(theta), std::sin(theta), 0 };
        };
        for (uint32_t i = 0; i < diskSegments; i++) {
            // wind to match the quad's -Z geometric normal
            diskPositions[i * 3 + 0] = F32x3 { 0, 0, 0 };
            diskPositions[i * 3 + 1] = rim(i + 1);
            diskPositions[i * 3 + 2] = rim(i);
            diskNormals[i * 3 + 0] = diskNormals[i * 3 + 1] = diskNormals[i * 3 + 2] = F32x3 { 0, 0, -1 };
        }
        _unitDisk = HdMoonshineCreateMesh(_moonshine, diskPositions, diskNormals, nullptr, diskSegments * 3);
    }

    HdMoonshine* _moonshine;

    // some defaults
    ImageHandle _black3;
    ImageHandle _black1;
    ImageHandle _upNormal;
    ImageHandle _grey3;
    ImageHandle _white1;
    MaterialHandle _defaultMaterial;
    MeshHandle _unitQuad;
    MeshHandle _unitDisk;
};

PXR_NAMESPACE_CLOSE_SCOPE