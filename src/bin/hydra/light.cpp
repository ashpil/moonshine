#include "moonshine.h"

#include "light.hpp"
#include "renderParam.hpp"

#include <pxr/imaging/hd/sceneDelegate.h>
#include <pxr/imaging/hio/image.h>
#include <pxr/imaging/hio/types.h>
#include <pxr/base/gf/vec3f.h>
#include <pxr/base/gf/half.h>
#include <pxr/base/gf/matrix3d.h>
#include <pxr/base/gf/matrix4d.h>
#include <pxr/base/gf/matrix4f.h>

#include <cmath>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

HdMoonshineDomeLight::HdMoonshineDomeLight(SdfPath const& id) : HdLight(id) {}

HdDirtyBits HdMoonshineDomeLight::GetInitialDirtyBitsMask() const {
    return HdLight::AllDirty;
}

// background_to_world (toWorld = R * D): maps a Moonshine env-local direction into world
// space, matching HdStorm's dome-light orientation.
//
//   R: the dome's world rotation. ExtractRotationMatrix is row-vector (v*M) but the consumer
//     wants M*v, so we GetTranspose(). We first fold in domeOffset exactly as HdStorm does
//     (hdSt/light.cpp): the effective dome transform is domeOffset * GetTransform, where
//     domeOffset is the pole-axis/up-axis correction UsdImaging exposes as a light param
//     for UsdLuxDomeLight_1 (e.g. +90deg about X in a Z-up stage). Classic UsdLuxDomeLight
//     carries its orientation in the authored transform instead and exposes no domeOffset.
//   D: the fixed Moonshine-env-local -> USD-dome-local map. Moonshine's env frame is
//     (see EnvMap in light.hlsl): image center -> +X, image right -> +Y, image top -> +Z.
//     USD's latlong dome-local frame (HdStorm domeLight.glslfx) places image center -> +Z,
//     image right -> -X, image top (zenith) -> +Y. So D sends env (+X,+Y,+Z) to dome
//     (+Z,-X,+Y). This is a reflection (det -1): Moonshine's equirect is the horizontal
//     mirror of USD's (Moonshine adds a half-turn azimuth offset "to match blender" in
//     equirectangular_to_equal_area.hlsl, which USD lacks).
static Mat3 ComputeBackgroundToWorld(HdSceneDelegate* sceneDelegate, SdfPath const& id) {
    GfMatrix4d xf = GfMatrix4d(sceneDelegate->GetTransform(id));
    const VtValue domeOffset = sceneDelegate->GetLightParamValue(id, HdLightTokens->domeOffset);
    if (domeOffset.IsHolding<GfMatrix4d>()) {
        xf = domeOffset.UncheckedGet<GfMatrix4d>() * xf;
    }

    const GfMatrix3d R = xf.ExtractRotationMatrix().GetTranspose();
    const GfMatrix3d D( 0,-1, 0,
                        0, 0, 1,
                        1, 0, 0 ); // env (+X,+Y,+Z) -> dome-local (+Z,-X,+Y)
    const GfMatrix3d toWorld = R * D;

    return Mat3 {
        .x = F32x3 { .x = (float)toWorld[0][0], .y = (float)toWorld[0][1], .z = (float)toWorld[0][2] },
        .y = F32x3 { .x = (float)toWorld[1][0], .y = (float)toWorld[1][1], .z = (float)toWorld[1][2] },
        .z = F32x3 { .x = (float)toWorld[2][0], .y = (float)toWorld[2][1], .z = (float)toWorld[2][2] },
    };
}

// whether Hio tagged this format as sRGB-encoded. sRGB-ness lives on the HioFormat (the
// "srgb" variants), not the HioType -- HioGetHioType folds linear and sRGB 8-bit both into
// HioTypeUnsignedByte -- so an 8-bit *linear* map must not be treated as sRGB. Hio derives
// the tag from the source's gamma / color space metadata (see Hio_StbImage::IsColorSpaceSRGB).
static bool IsSRGBFormat(HioFormat format) {
    switch (format) {
        case HioFormatUNorm8srgb:
        case HioFormatUNorm8Vec2srgb:
        case HioFormatUNorm8Vec3srgb:
        case HioFormatUNorm8Vec4srgb:
        case HioFormatBC7UNorm8Vec4srgb:
            return true;
        default:
            return false;
    }
}

void HdMoonshineDomeLight::Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits) {
    HdMoonshine* msne = static_cast<HdMoonshineRenderParam*>(renderParam)->_moonshine;
    SdfPath const& id = GetId();

    const float intensity = sceneDelegate->GetLightParamValue(id, HdLightTokens->intensity).GetWithDefault(1.0f);
    const float exposure = sceneDelegate->GetLightParamValue(id, HdLightTokens->exposure).GetWithDefault(0.0f);
    const GfVec3f color = sceneDelegate->GetLightParamValue(id, HdLightTokens->color).GetWithDefault(GfVec3f(1.0f));
    const float scale = intensity * std::exp2(exposure);
    const GfVec3f tint = color * scale;

    const Mat3 transform = ComputeBackgroundToWorld(sceneDelegate, id);

    std::string texturePath;
    VtValue textureValue = sceneDelegate->GetLightParamValue(id, HdLightTokens->textureFile);
    if (textureValue.IsHolding<SdfAssetPath>()) {
        const SdfAssetPath asset = textureValue.UncheckedGet<SdfAssetPath>();
        texturePath = asset.GetResolvedPath();
        if (texturePath.empty()) {
            texturePath = asset.GetAssetPath();
        }
    }

    if (!texturePath.empty()) {
        HioImageSharedPtr image = HioImage::OpenForReading(texturePath);
        if (!image) {
            TF_CODING_ERROR("dome light %s could not open texture %s", id.GetText(), texturePath.c_str());
            return;
        }

        // This USD build's Hio_StbImage plugin only reads in the image's native format, so
        // read native and hand the raw bytes to the GPU, which interprets them via the
        // upload format -- including sRGB->linear in the sampler. We never decode or
        // linearize on the CPU here.
        const HioFormat format = image->GetFormat();
        const HioType type = HioGetHioType(format);
        const int componentCount = HioGetComponentCount(format);
        const size_t pixelBytes = image->GetBytesPerPixel();
        if (type != HioTypeUnsignedByte && type != HioTypeHalfFloat && type != HioTypeFloat) {
            TF_CODING_ERROR("dome light %s texture %s has unsupported type %d", id.GetText(), texturePath.c_str(), type);
            return;
        }

        HioImage::StorageSpec spec;
        spec.width = image->GetWidth();
        spec.height = image->GetHeight();
        spec.format = format;
        spec.flipped = false;
        const size_t pixelCount = static_cast<size_t>(spec.width) * spec.height;
        std::vector<uint8_t> raw(pixelCount * pixelBytes);
        spec.data = raw.data();
        if (!image->Read(spec)) {
            TF_CODING_ERROR("dome light %s could not read texture %s", id.GetText(), texturePath.c_str());
            return;
        }

        const Extent2D extent = Extent2D { .width = static_cast<uint32_t>(spec.width), .height = static_cast<uint32_t>(spec.height) };
        const bool hasTint = tint[0] != 1.0f || tint[1] != 1.0f || tint[2] != 1.0f;

        if (IsSRGBFormat(format)) {
            // non-linear source: upload the raw 8-bit bytes and let the GPU sampler do the
            // sRGB->linear decode. There's no correct place to fold the tint into sRGB-encoded
            // bytes, so it's dropped -- warn if it was actually set to something visible.
            if (hasTint) {
                TF_WARN("dome light %s: intensity/exposure/color is ignored for non-linear (sRGB) texture %s", id.GetText(), texturePath.c_str());
            }
            std::vector<uint8_t> rgba(pixelCount * 4);
            for (size_t i = 0; i < pixelCount; i++) {
                const uint8_t* px = raw.data() + i * pixelBytes;
                uint8_t v[3] = { 0, 0, 0 };
                for (int c = 0; c < componentCount && c < 3; c++) v[c] = px[c];
                if (componentCount == 1) { v[1] = v[0]; v[2] = v[0]; } // splat single channel to grey
                rgba[i * 4 + 0] = v[0];
                rgba[i * 4 + 1] = v[1];
                rgba[i * 4 + 2] = v[2];
                rgba[i * 4 + 3] = 255;
            }
            HdMoonshineSetEnvMap(msne, rgba.data(), extent, u8x4_srgb, transform);
        } else {
            // linear source (float/half/linear-8-bit): decode to float so the tint can be
            // folded in, then upload as linear f32x4.
            auto channel = [&](const uint8_t* px, int c) -> float {
                switch (type) {
                    case HioTypeUnsignedByte: return px[c] / 255.0f;
                    case HioTypeHalfFloat:    return static_cast<float>(reinterpret_cast<const GfHalf*>(px)[c]);
                    case HioTypeFloat:        return reinterpret_cast<const float*>(px)[c];
                    default:                  return 0.0f;
                }
            };
            std::vector<F32x4> data(pixelCount);
            for (size_t i = 0; i < pixelCount; i++) {
                const uint8_t* px = raw.data() + i * pixelBytes;
                float rgb[3] = { 0.0f, 0.0f, 0.0f };
                for (int c = 0; c < componentCount && c < 3; c++) rgb[c] = channel(px, c);
                if (componentCount == 1) { rgb[1] = rgb[0]; rgb[2] = rgb[0]; } // splat single channel to grey
                data[i] = F32x4 { .x = rgb[0] * tint[0], .y = rgb[1] * tint[1], .z = rgb[2] * tint[2], .w = 1.0f };
            }
            HdMoonshineSetEnvMap(msne, reinterpret_cast<const uint8_t*>(data.data()), extent, f32x4, transform);
        }
    } else {
        F32x4 texel = F32x4 { .x = tint[0], .y = tint[1], .z = tint[2], .w = 1.0f };
        Extent2D extent = Extent2D { .width = 1, .height = 1 };
        HdMoonshineSetEnvMap(msne, reinterpret_cast<const uint8_t*>(&texel), extent, f32x4, transform);
    }

    *dirtyBits = HdChangeTracker::Clean;
}

HdMoonshineAreaLight::HdMoonshineAreaLight(SdfPath const& id, HdMoonshineRenderParam& renderParam) : HdLight(id) {
    // black diffuse body; emission is set during Sync
    _material = HdMoonshineCreateMaterial(renderParam._moonshine, Material {
        .normal = renderParam._upNormal,
        .emissive = renderParam._black3,
        .color = renderParam._black3,
        .metalness = renderParam._black1,
        .roughness = renderParam._white1,
        .ior = 1.5,
    });
}

HdDirtyBits HdMoonshineAreaLight::GetInitialDirtyBitsMask() const {
    return HdLight::AllDirty;
}

void HdMoonshineAreaLight::Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* hdRenderParam, HdDirtyBits* dirtyBits) {
    HdMoonshineRenderParam* renderParam = static_cast<HdMoonshineRenderParam*>(hdRenderParam);
    HdMoonshine* msne = renderParam->_moonshine;
    SdfPath const& id = GetId();

    const float intensity = sceneDelegate->GetLightParamValue(id, HdLightTokens->intensity).GetWithDefault(1.0f);
    const float exposure = sceneDelegate->GetLightParamValue(id, HdLightTokens->exposure).GetWithDefault(0.0f);
    const GfVec3f color = sceneDelegate->GetLightParamValue(id, HdLightTokens->color).GetWithDefault(GfVec3f(1.0f));
    const bool normalize = sceneDelegate->GetLightParamValue(id, HdLightTokens->normalize).GetWithDefault(false);

    const Shape shape = ComputeShape(sceneDelegate, *renderParam);

    const GfMatrix4f xform = GfMatrix4f(sceneDelegate->GetTransform(id));

    float scale = intensity * std::exp2(exposure);
    // normalize divides by the light's world-space surface area,
    // including any scaling from the transform stack
    if (normalize) {
        const GfVec3f worldX = xform.TransformDir(GfVec3f::XAxis());
        const GfVec3f worldY = xform.TransformDir(GfVec3f::YAxis());
        const float worldArea = shape.area * GfCross(worldX, worldY).GetLength();
        if (worldArea > 0) {
            scale /= worldArea;
        }
    }
    const GfVec3f radiance = color * scale;

    if (radiance != _radiance) {
        F32x4 texel = F32x4 { .x = radiance[0], .y = radiance[1], .z = radiance[2], .w = 1.0f };
        const Extent2D extent = Extent2D { .width = 1, .height = 1 };
        const ImageHandle texture = HdMoonshineCreateTexture(msne, reinterpret_cast<uint8_t*>(&texel), extent, TextureFormat::f32x4, (id.GetString() + " emission").c_str());
        HdMoonshineSetMaterialEmissive(msne, _material, texture);
        _radiance = radiance;
    }

    // the shared meshes are unit-sized; bake the authored dimensions in as scale
    GfMatrix4f scaleMat;
    scaleMat.SetScale(GfVec3f(shape.size[0], shape.size[1], 1.0f));
    const GfMatrix4f transform = scaleMat * xform;
    const Mat4x3 matrix = Mat4x3 {
        .x = F32x4 { .x = transform[0][0], .y = transform[1][0], .z = transform[2][0], .w = transform[3][0] },
        .y = F32x4 { .x = transform[0][1], .y = transform[1][1], .z = transform[2][1], .w = transform[3][1] },
        .z = F32x4 { .x = transform[0][2], .y = transform[1][2], .z = transform[2][2], .w = transform[3][2] },
    };

    const bool visible = sceneDelegate->GetVisible(id);

    // always touch the instance: this marks instances dirty, which also rebuilds the
    // light power hierarchy so emission changes actually take effect
    if (_instance) {
        HdMoonshineSetInstance(msne, *_instance, matrix, visible);
    } else {
        _instance = HdMoonshineCreateInstance(msne, matrix, shape.mesh, _material, visible);
    }

    *dirtyBits = HdChangeTracker::Clean;
}

void HdMoonshineAreaLight::Finalize(HdRenderParam* renderParam) {
    if (_instance) {
        HdMoonshineDestroyInstance(static_cast<HdMoonshineRenderParam*>(renderParam)->_moonshine, *_instance);
        _instance.reset();
    }
}

HdMoonshineAreaLight::Shape HdMoonshineRectLight::ComputeShape(HdSceneDelegate* sceneDelegate, HdMoonshineRenderParam& renderParam) const {
    SdfPath const& id = GetId();
    const float width = sceneDelegate->GetLightParamValue(id, HdLightTokens->width).GetWithDefault(1.0f);
    const float height = sceneDelegate->GetLightParamValue(id, HdLightTokens->height).GetWithDefault(1.0f);

    const VtValue textureValue = sceneDelegate->GetLightParamValue(id, HdLightTokens->textureFile);
    if (textureValue.IsHolding<SdfAssetPath>() && !textureValue.UncheckedGet<SdfAssetPath>().GetAssetPath().empty()) {
        TF_WARN("rect light %s: textureFile is not supported, using constant color", id.GetText());
    }

    return Shape { .mesh = renderParam._unitQuad, .size = GfVec2f(width, height), .area = width * height };
}

HdMoonshineAreaLight::Shape HdMoonshineDiskLight::ComputeShape(HdSceneDelegate* sceneDelegate, HdMoonshineRenderParam& renderParam) const {
    const float radius = sceneDelegate->GetLightParamValue(GetId(), HdLightTokens->radius).GetWithDefault(0.5f);
    return Shape { .mesh = renderParam._unitDisk, .size = GfVec2f(radius, radius), .area = (float)M_PI * radius * radius };
}

void HdMoonshineDomeLight::Finalize(HdRenderParam* renderParam) {
    // removing the dome restores the USD-correct (no environment) default
    HdMoonshine* msne = static_cast<HdMoonshineRenderParam*>(renderParam)->_moonshine;
    F32x4 black = F32x4 { .x = 0.0f, .y = 0.0f, .z = 0.0f, .w = 1.0f };
    Mat3 identity = Mat3 {
        .x = F32x3 { .x = 1.0f, .y = 0.0f, .z = 0.0f },
        .y = F32x3 { .x = 0.0f, .y = 1.0f, .z = 0.0f },
        .z = F32x3 { .x = 0.0f, .y = 0.0f, .z = 1.0f },
    };
    Extent2D extent = Extent2D { .width = 1, .height = 1 };
    HdMoonshineSetEnvMap(msne, reinterpret_cast<const uint8_t*>(&black), extent, f32x4, identity);
}

PXR_NAMESPACE_CLOSE_SCOPE
