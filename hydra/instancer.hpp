#pragma once

#include "moonshine.h"

#include "pxr/pxr.h"
#include "pxr/imaging/hd/instancer.h"

class HdMoonshineInstancer : public PXR_NS::HdInstancer {
public:
    HdMoonshineInstancer(PXR_NS::HdSceneDelegate* delegate, PXR_NS::SdfPath const& id);
    ~HdMoonshineInstancer();

    void Sync(PXR_NS::HdSceneDelegate *sceneDelegate, PXR_NS::HdRenderParam *renderParam, PXR_NS::HdDirtyBits *dirtyBits) override;
    PXR_NS::VtMatrix4dArray ComputeInstanceTransforms(const PXR_NS::SdfPath& prototypeId);
private:
    PXR_NS::TfHashMap<PXR_NS::TfToken, PXR_NS::VtValue, PXR_NS::TfToken::HashFunctor> primvarMap_;
};