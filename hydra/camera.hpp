#pragma once

#include "moonshine.h"

#include "pxr/pxr.h"
#include "pxr/imaging/hd/camera.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineCamera final : public HdCamera {
public:
    HdMoonshineCamera(SdfPath const& id);
    ~HdMoonshineCamera() override = default;

    void Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits) override;

    LensHandle _handle = -1;
protected:
    HdMoonshineCamera(const HdMoonshineCamera&) = delete;
    HdMoonshineCamera &operator =(const HdMoonshineCamera&) = delete;
};

PXR_NAMESPACE_CLOSE_SCOPE
