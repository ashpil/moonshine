#pragma once

#include "pxr/pxr.h"
#include "pxr/imaging/hd/renderPass.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineRenderPass final : public HdRenderPass
{
public:
    HdMoonshineRenderPass(HdRenderIndex *index, HdRprimCollection const &collection);
    ~HdMoonshineRenderPass() override;
protected:
    void _Execute(HdRenderPassStateSharedPtr const& renderPassState, TfTokenVector const& renderTags) override;
};

PXR_NAMESPACE_CLOSE_SCOPE
