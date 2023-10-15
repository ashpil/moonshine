#pragma once

#include "pxr/pxr.h"
#include "pxr/imaging/hd/renderPass.h"

class HdMoonshineRenderPass final : public PXR_NS::HdRenderPass 
{
public:
    HdMoonshineRenderPass(PXR_NS::HdRenderIndex *index, PXR_NS::HdRprimCollection const &collection);
    ~HdMoonshineRenderPass() override;
protected:
    void _Execute(PXR_NS::HdRenderPassStateSharedPtr const& renderPassState, PXR_NS::TfTokenVector const& renderTags) override;
};
