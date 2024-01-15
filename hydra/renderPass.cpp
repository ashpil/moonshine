#include "moonshine.h"

#include "camera.hpp"
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
    for (const auto aov : renderPassState->GetAovBindings()) {
        if (aov.aovName == PXR_NS::HdAovTokens->color) {
            PXR_NS::HdRenderIndex* renderIndex = GetRenderIndex();
            HdMoonshineRenderDelegate* renderDelegate = static_cast<HdMoonshineRenderDelegate*>(renderIndex->GetRenderDelegate());
            const HdMoonshineCamera* camera = static_cast<const HdMoonshineCamera*>(renderPassState->GetCamera());

            HdMoonshineRenderBuffer* renderBuffer = static_cast<HdMoonshineRenderBuffer*>(aov.renderBuffer);
            HdMoonshineRender(renderDelegate->_moonshine, renderBuffer->_sensor, camera->_handle);
        }
    }
}
