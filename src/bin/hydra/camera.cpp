#include "moonshine.h"

#include "camera.hpp"
#include "renderDelegate.hpp"

#include <pxr/base/gf/matrix4f.h>
#include <pxr/imaging/hd/renderIndex.h>
#include <pxr/imaging/hd/sceneDelegate.h>

PXR_NAMESPACE_OPEN_SCOPE

HdMoonshineCamera::HdMoonshineCamera(SdfPath const& id) : HdCamera(id) {}

void HdMoonshineCamera::Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits) {
    HdCamera::Sync(sceneDelegate, renderParam, dirtyBits);
    HdMoonshine* msne = static_cast<HdMoonshineRenderParam*>(renderParam)->_moonshine;

    static const GfMatrix4f usdCameraToMoonshineCamera(
        0,  0, -1, 0,   // moonshine X = -USD Z
        1,  0,  0, 0,   // moonshine Y =  USD X
        0,  1,  0, 0,   // moonshine Z =  USD Y (flips image to USD's bottom-up origin)
        0,  0,  0, 1);  // origin passthrough
    GfMatrix4f transform = usdCameraToMoonshineCamera * GfMatrix4f(GetTransform());

    const Mat4x3 matrix = Mat4x3 {
        .x = F32x4 { .x = transform[0][0], .y = transform[1][0], .z = transform[2][0], .w = transform[3][0] },
        .y = F32x4 { .x = transform[0][1], .y = transform[1][1], .z = transform[2][1], .w = transform[3][1] },
        .z = F32x4 { .x = transform[0][2], .y = transform[1][2], .z = transform[2][2], .w = transform[3][2] },
    };

    Camera camera = Camera {
        .transform = matrix,
        .model = (GetProjection() == HdCamera::Orthographic) ? CameraModelOrthographic : CameraModelThinLens,
        .thin_lens = ThinLens {
            .vfov = 2.0f * std::atan(GetVerticalAperture() / (2.0f * GetFocalLength())),
            .aperture = 0,
            .focus_distance = 1,
        },
        .orthographic = ::Orthographic {
            .vscale = GetVerticalAperture() / 2.0f,
        },
    };

    if (_handle == -1) {
        _handle = HdMoonshineCreateCamera(msne, camera, "camera");
    } else {
        HdMoonshineSetCamera(msne, _handle, camera);
    }
}

PXR_NAMESPACE_CLOSE_SCOPE
