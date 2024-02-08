#pragma once

#include "pxr/pxr.h"
#include "pxr/imaging/hd/mesh.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineMesh final : public HdMesh {
public:
    HdMoonshineMesh(SdfPath const& id);
    ~HdMoonshineMesh() override = default;

    HdDirtyBits GetInitialDirtyBitsMask() const override;

    void Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits, TfToken const &reprToken) override;

protected:
    void _InitRepr(TfToken const &reprToken, HdDirtyBits *dirtyBits) override;

    HdDirtyBits _PropagateDirtyBits(HdDirtyBits bits) const override;

    HdMoonshineMesh(const HdMoonshineMesh&) = delete;
    HdMoonshineMesh &operator =(const HdMoonshineMesh&) = delete;
private:
    bool initialized_ = false; // don't allow updating for now, only initialization
};

PXR_NAMESPACE_CLOSE_SCOPE
