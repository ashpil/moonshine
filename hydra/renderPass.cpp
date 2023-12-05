#include "moonshine.h"

#include "renderPass.hpp"
#include "renderBuffer.hpp"
#include "renderDelegate.hpp"

#include <pxr/imaging/hd/renderPassState.h>
#include <pxr/imaging/hd/tokens.h>

#include <iostream>

HdMoonshineRenderPass::HdMoonshineRenderPass(PXR_NS::HdRenderIndex *index, PXR_NS::HdRprimCollection const &collection) : HdRenderPass(index, collection) {
    std::cout << "Creating renderPass" << std::endl;
}

HdMoonshineRenderPass::~HdMoonshineRenderPass() {
    std::cout << "Destroying renderPass" << std::endl;
}

void HdMoonshineRenderPass::_Execute(PXR_NS::HdRenderPassStateSharedPtr const& renderPassState, PXR_NS::TfTokenVector const& renderTags) {
    std::cout << "=> Execute RenderPass" << std::endl;
    for (const auto aov : renderPassState->GetAovBindings()) {
        if (aov.aovName == PXR_NS::HdAovTokens->color) {
            std::cout << aov << std::endl;
            PXR_NS::HdRenderIndex* renderIndex = GetRenderIndex();
            HdMoonshineRenderDelegate* renderDelegate = static_cast<HdMoonshineRenderDelegate*>(renderIndex->GetRenderDelegate());
            HdMoonshineRenderBuffer* renderBuffer = static_cast<HdMoonshineRenderBuffer*>(aov.renderBuffer);
            HdMoonshineRender(renderDelegate->_moonshine, static_cast<float*>(renderBuffer->Map()));
            renderBuffer->Unmap();
        }
    }
}
