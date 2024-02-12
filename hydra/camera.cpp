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

    GfMatrix4f transform = GfMatrix4f(GetTransform());
    GfVec3f origin = transform.Transform(GfVec3f(0.0, 0.0, 0.0));
    GfVec3f forward = transform.TransformDir(GfVec3f(0.0, 0.0, -1.0));
    GfVec3f up = transform.TransformDir(GfVec3f(0.0, 1.0, 0.0));

    forward.Normalize();
    up.Normalize();

    Lens lens = Lens {
        .origin = F32x3 { .x = origin[0], .y = origin[1], .z = origin[2] },
        .forward = F32x3 { .x = forward[0], .y = forward[1], .z = forward[2] },
        .up = F32x3 { .x = up[0], .y = up[1], .z = up[2] },
        .vfov = 2.0f * std::atan(GetVerticalAperture() / (2.0f * GetFocalLength())),
        .aperture = 0,
        .focus_distance = 1,
    };

    if (_handle == -1) {
        _handle = HdMoonshineCreateLens(msne, lens);
    } else {
        HdMoonshineSetLens(msne, _handle, lens);
    }
}

PXR_NAMESPACE_CLOSE_SCOPE
