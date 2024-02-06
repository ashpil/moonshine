#pragma once

#include "pxr/pxr.h"
#include "pxr/imaging/hd/mesh.h"

class HdMoonshineMesh final : public PXR_NS::HdMesh {
public:
    HdMoonshineMesh(PXR_NS::SdfPath const& id);
    ~HdMoonshineMesh() override = default;

    PXR_NS::HdDirtyBits GetInitialDirtyBitsMask() const override;

    void Sync(PXR_NS::HdSceneDelegate* sceneDelegate, PXR_NS::HdRenderParam* renderParam, PXR_NS::HdDirtyBits* dirtyBits, PXR_NS::TfToken const &reprToken) override;

protected:
    void _InitRepr(PXR_NS::TfToken const &reprToken, PXR_NS::HdDirtyBits *dirtyBits) override;

    PXR_NS::HdDirtyBits _PropagateDirtyBits(PXR_NS::HdDirtyBits bits) const override;

    HdMoonshineMesh(const HdMoonshineMesh&) = delete;
    HdMoonshineMesh &operator =(const HdMoonshineMesh&) = delete;
private:
    bool initialized_ = false; // don't allow updating for now, only initialization
};

