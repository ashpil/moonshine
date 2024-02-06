#include "moonshine.h"

#include "camera.hpp"
#include "renderDelegate.hpp"

#include <pxr/base/gf/matrix4f.h>
#include <pxr/imaging/hd/renderIndex.h>
#include <pxr/imaging/hd/sceneDelegate.h>

#include <iostream>

HdMoonshineCamera::HdMoonshineCamera(PXR_NS::SdfPath const& id) : PXR_NS::HdCamera(id) {
    std::cout << "Camera constructor id=" << GetId() << std::endl;
}

PXR_NS::HdDirtyBits HdMoonshineCamera::GetInitialDirtyBitsMask() const {
    std::cout << "* (multithreaded) Get Initial Dirty Bits Mask id==" << GetId() << std::endl;
    return PXR_NS::HdChangeTracker::DirtyTransform;
}

void HdMoonshineCamera::Sync(PXR_NS::HdSceneDelegate* sceneDelegate, PXR_NS::HdRenderParam* renderParam, PXR_NS::HdDirtyBits* dirtyBits) {
    PXR_NS::HdCamera::Sync(sceneDelegate, renderParam, dirtyBits);
    PXR_NS::HdRenderIndex& renderIndex = sceneDelegate->GetRenderIndex();
    HdMoonshineRenderDelegate* renderDelegate = static_cast<HdMoonshineRenderDelegate*>(renderIndex.GetRenderDelegate());

    PXR_NS::GfMatrix4f transform = PXR_NS::GfMatrix4f(GetTransform());
    PXR_NS::GfVec3f origin = transform.Transform(PXR_NS::GfVec3f(0.0, 0.0, 0.0));
    PXR_NS::GfVec3f forward = transform.TransformDir(PXR_NS::GfVec3f(0.0, 0.0, -1.0));
    PXR_NS::GfVec3f up = transform.TransformDir(PXR_NS::GfVec3f(0.0, 1.0, 0.0));

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
        _handle = HdMoonshineCreateLens(renderDelegate->_moonshine, lens);
    } else {
        HdMoonshineSetLens(renderDelegate->_moonshine, _handle, lens);
    }
    *dirtyBits = PXR_NS::HdChangeTracker::Clean;
}

