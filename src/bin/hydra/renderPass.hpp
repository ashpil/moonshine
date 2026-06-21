#pragma once

#include "pxr/pxr.h"
#include "pxr/base/gf/matrix4d.h"
#include "pxr/imaging/hd/renderPass.h"
#include "pxr/imaging/hd/renderPassState.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineRenderPass final : public HdRenderPass
{
public:
    HdMoonshineRenderPass(HdRenderIndex *index, HdRprimCollection const &collection);
    ~HdMoonshineRenderPass() override;

    bool IsConverged() const override;
protected:
    void _Execute(HdRenderPassStateSharedPtr const& renderPassState, TfTokenVector const& renderTags) override;
private:
    // cached render-pass state used to decide when to reset accumulation
    GfMatrix4d _viewMatrix = GfMatrix4d(1.0);
    GfMatrix4d _projMatrix = GfMatrix4d(1.0);
    unsigned int _lastSceneVersion = 0;
    unsigned int _lastPipelineVersion = 0;
    HdRenderPassAovBindingVector _aovBindings;
};

PXR_NAMESPACE_CLOSE_SCOPE
