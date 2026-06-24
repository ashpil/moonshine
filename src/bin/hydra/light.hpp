#pragma once

#include "moonshine.h"

#include "pxr/pxr.h"
#include "pxr/imaging/hd/light.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineDomeLight final : public HdLight {
public:
    HdMoonshineDomeLight(SdfPath const& id);
    ~HdMoonshineDomeLight() override = default;

    void Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits) override;

    HdDirtyBits GetInitialDirtyBitsMask() const override;

    void Finalize(HdRenderParam* renderParam) override;
protected:
    HdMoonshineDomeLight(const HdMoonshineDomeLight&) = delete;
    HdMoonshineDomeLight &operator =(const HdMoonshineDomeLight&) = delete;
};

PXR_NAMESPACE_CLOSE_SCOPE
