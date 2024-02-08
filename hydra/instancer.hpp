#pragma once

#include "moonshine.h"

#include "pxr/pxr.h"
#include "pxr/imaging/hd/instancer.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineInstancer : public HdInstancer {
public:
    HdMoonshineInstancer(HdSceneDelegate* delegate, SdfPath const& id);
    ~HdMoonshineInstancer();

    void Sync(HdSceneDelegate *sceneDelegate, HdRenderParam *renderParam, HdDirtyBits *dirtyBits) override;
    VtMatrix4dArray ComputeInstanceTransforms(const SdfPath& prototypeId);
private:
    TfHashMap<TfToken, VtValue, TfToken::HashFunctor> primvarMap_;
};

PXR_NAMESPACE_CLOSE_SCOPE
