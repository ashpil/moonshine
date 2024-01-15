#include "moonshine.h"

#include "camera.hpp"
#include "renderDelegate.hpp"

#include <ostream>
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

    PXR_NS::GfMatrix4d transform = GetTransform();
    PXR_NS::GfVec3d origin = transform.Transform(PXR_NS::GfVec3d(0.0, 0.0, 0.0));
    PXR_NS::GfVec3d forward = transform.TransformDir(PXR_NS::GfVec3d(0.0, 0.0, -1.0));
    PXR_NS::GfVec3d up = transform.TransformDir(PXR_NS::GfVec3d(0.0, 1.0, 0.0));

    forward.Normalize();
    up.Normalize();

    Lens lens = Lens {
        .origin = F32x3 { .x = static_cast<float>(origin[0]), .y = static_cast<float>(origin[1]), .z = static_cast<float>(origin[2]) },
        .forward = F32x3 { .x = static_cast<float>(forward[0]), .y = static_cast<float>(forward[1]), .z = static_cast<float>(forward[2]) },
        .up = F32x3 { .x = static_cast<float>(up[0]), .y = static_cast<float>(up[1]), .z = static_cast<float>(up[2]) },
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

