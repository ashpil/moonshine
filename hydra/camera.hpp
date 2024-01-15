#pragma once

#include "moonshine.h"

#include "pxr/pxr.h"
#include "pxr/imaging/hd/camera.h"

class HdMoonshineCamera final : public PXR_NS::HdCamera {
public:
    HdMoonshineCamera(PXR_NS::SdfPath const& id);
    ~HdMoonshineCamera() override = default;

    PXR_NS::HdDirtyBits GetInitialDirtyBitsMask() const override;

    void Sync(PXR_NS::HdSceneDelegate* sceneDelegate, PXR_NS::HdRenderParam* renderParam, PXR_NS::HdDirtyBits* dirtyBits) override;

    LensHandle _handle = -1;
protected:
    HdMoonshineCamera(const HdMoonshineCamera&) = delete;
    HdMoonshineCamera &operator =(const HdMoonshineCamera&) = delete;
};

